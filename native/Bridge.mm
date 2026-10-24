// Runtime-only compatibility bridge for the exact Logic 12.4 (6707) ABI.
// The launcher must start a verified private copy. No Apple file is written here.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Carbon/Carbon.h>
#import <objc/runtime.h>
#include <CommonCrypto/CommonDigest.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <atomic>
#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits.h>

namespace {
constexpr char kEngineRelative[] = "Contents/Frameworks/MAAudioEngine.framework/Versions/A/MAAudioEngine";
constexpr char kCoreRelative[] = "Contents/Frameworks/MACore.framework/Versions/A/MACore";
constexpr char kEngineSHA256[] = "f1ec685f407cd8a9ec73d3e94cdf3f7929bdcaa2168f221913c950bae76fec24";
constexpr char kCoreSHA256[] = "331ce81830f253f3d47f9a219264a51c92bd1d66f03cafd166f04a8b5d6a745b";
constexpr uint32_t fourCC(char a, char b, char c, char d) {
    return (uint32_t(a) << 24) | (uint32_t(b) << 16) | (uint32_t(c) << 8) | uint32_t(d);
}
constexpr uint32_t kAUv2 = fourCC('a', 'u', 'v', '2');
constexpr uint32_t kARAM = fourCC('a', 'r', 'a', 'm');
constexpr uint32_t kARAX = fourCC('a', 'r', 'a', 'x');

FILE* logFile;
pthread_mutex_t logMutex = PTHREAD_MUTEX_INITIALIZER;
std::atomic<bool> active{false};
// Runtime compatibility failure must not undo preference/process isolation or
// tear down a native document that the original setup already owns.
std::atomic<bool> nativeARASetupEnabled{true};
CFStringRef preferenceDomain;
NSUserDefaults* isolatedDefaults;
void** tagPlistVtable;

using SetupFn = void (*)(void*);
using CreateAUFn = AudioUnit (*)(void*);
// The native getter performs AraF magic/API-generation validation. The bridge
// never dereferences the opaque factory and therefore needs no ARA SDK headers.
using GetFactoryFn = const void* (*)(void*, AudioUnit);
SetupFn originalSetup;
CreateAUFn createNativeAU;
GetFactoryFn getNativeFactory;
using ReadSamplesFn = int32_t (*)(void*, void*, int64_t, int64_t, void* const*);
using StreamModeFn = int32_t (*)(void*);
ReadSamplesFn originalReadSamples;
StreamModeFn originalStreamMode;
void** sourceVtable;
void** streamVtable;
void* regionEntryVtable;
thread_local void* stereoReaderStream;
thread_local unsigned stereoReaderCorrections;
std::atomic<unsigned> stereoReaderLogCount{0};

template<class T> bool readSelf(uintptr_t address, T& value) {
    if (!address) return false;
    mach_vm_size_t copied = 0;
    return mach_vm_read_overwrite(mach_task_self(), address, sizeof(T),
        reinterpret_cast<mach_vm_address_t>(&value), &copied) == KERN_SUCCESS && copied == sizeof(T);
}

void logLine(const char* format, ...) {
    if (!logFile) return;
    pthread_mutex_lock(&logMutex);
    fprintf(logFile, "pid=%d ", getpid());
    va_list args;
    va_start(args, format);
    vfprintf(logFile, format, args);
    va_end(args);
    fputc('\n', logFile);
    fflush(logFile);
    pthread_mutex_unlock(&logMutex);
}

[[noreturn]] void refuse(const char* reason) {
    logLine("bridge_refused reason=%s", reason);
    _exit(78);
}

void reportRuntimeSetupFailure(const char* reason) {
    const bool first = nativeARASetupEnabled.exchange(false, std::memory_order_acq_rel);
    logLine("bridge_runtime_degraded reason=%s native_document_preserved=1 callback_modified=0 future_discovery_disabled=1 compatibility_valid=0", reason);
#if !defined(LOGIC_ARA_BRIDGE_TEST)
    if (first) {
        NSString* detail = [NSString stringWithUTF8String:reason];
        // Do not enter AppKit or a modal loop inside a native setup callback.
        // This addresses only this process and never closes a document/app.
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert* alert = [[NSAlert alloc] init];
            alert.alertStyle = NSAlertStyleCritical;
            alert.messageText = @"ARA compatibility was paused";
            alert.informativeText = [NSString stringWithFormat:
                @"Logic remains open. This ARA instance has not passed compatibility checks. Save your work, remove the affected ARA insert, and restart the launcher before continuing ARA editing.\n\nTechnical reason: %@", detail];
            [alert addButtonWithTitle:@"Keep Logic Open"];
            [alert runModal];
        });
    }
#else
    (void)first; // Offline tests execute the real setup guard without AppKit UI.
#endif
}

// Logic's shared ARA interface precreates regions with its first track's
// MDStream. ARA source access must still return the original two channels,
// independent of that track's playback mode. Keep the normal decoder and
// reader, changing only their mode query during this exact source read.
// No stored track mode or region association is changed.
void* stereoSourceStream(void* reader) {
    const uintptr_t source = reinterpret_cast<uintptr_t>(reader);
    uintptr_t vtable = 0, list = 0, entry = 0;
    uint32_t channels = 0;
    if (!readSelf(source, vtable) || vtable != reinterpret_cast<uintptr_t>(sourceVtable) ||
        !readSelf(source + 0x64, channels) || channels != 2 ||
        !readSelf(source + 0xb0, list) || !list || !readSelf(list + 0x20, entry)) return nullptr;
    // Match ReadFrames' first usable region, including its null-region failure
    // and CEntry::Next behavior. Bound corrupt/cyclic lists without dereferencing
    // unverified memory. An unrecognized layout keeps the original behavior.
    for (unsigned traversed = 0; entry && traversed < 4096; ++traversed) {
        uintptr_t entryTable = 0, region = 0, file = 0, stream = 0, streamTable = 0;
        if (!readSelf(entry, entryTable) || entryTable != reinterpret_cast<uintptr_t>(regionEntryVtable) ||
            !readSelf(entry + 0x28, region) || !region || !readSelf(region + 0x40, file)) return nullptr;
        if (file) {
            if (!readSelf(region + 0xd8, stream) || !stream || !readSelf(stream, streamTable) ||
                streamTable != reinterpret_cast<uintptr_t>(streamVtable)) return nullptr;
            return reinterpret_cast<void*>(stream);
        }
        if (!readSelf(entry + 0x18, entry)) return nullptr;
    }
    return nullptr;
}

int32_t sourceReadStreamMode(void* stream) {
    const int32_t mode = originalStreamMode(stream);
    if (stream == stereoReaderStream && mode == 0) {
        ++stereoReaderCorrections;
        return 1; // Standard stereo, solely inside a two-channel source read.
    }
    return mode;
}

int32_t readNativeSourceSamples(void* host, void* reader, int64_t position,
                                int64_t count, void* const* buffers) {
    struct SourceReadScope {
        void* previousStream = stereoReaderStream;
        unsigned previousCorrections = stereoReaderCorrections;
        explicit SourceReadScope(void* stream) { stereoReaderStream = stream; stereoReaderCorrections = 0; }
        ~SourceReadScope() { stereoReaderStream = previousStream; stereoReaderCorrections = previousCorrections; }
    };
    void* const stream = stereoSourceStream(reader);
    const int32_t storedModeBefore = stream ? originalStreamMode(stream) : -1;
    int32_t result;
    unsigned corrections;
    {
        SourceReadScope scope(stream);
        result = originalReadSamples(host, reader, position, count, buffers);
        corrections = stereoReaderCorrections;
    }
    if (corrections && stereoReaderLogCount.fetch_add(1, std::memory_order_relaxed) < 32) {
        logLine("ara_stereo_source_read channels=2 position=%lld count=%lld status=%d mode_before=%d mode_after=%d scoped_mode_queries=%u",
            static_cast<long long>(position), static_cast<long long>(count), result,
            storedModeBefore, originalStreamMode(stream), corrections);
    }
    return result;
}

void replaceDataPointer(void** slot, void* expected, void* replacement) {
    if (*slot != expected) refuse("compatibility_data_slot_mismatch");
    mach_vm_address_t address = reinterpret_cast<mach_vm_address_t>(slot);
    mach_vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t regionInfo{};
    mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    if (mach_vm_region(mach_task_self(), &address, &regionSize, VM_REGION_BASIC_INFO_64,
            reinterpret_cast<vm_region_info_t>(&regionInfo), &infoCount, &objectName) != KERN_SUCCESS)
        refuse("compatibility_data_region_unavailable");
    if (objectName != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), objectName);
    const mach_vm_address_t page = reinterpret_cast<uintptr_t>(slot) & ~(uintptr_t(getpagesize()) - 1);
    if (mach_vm_protect(mach_task_self(), page, getpagesize(), false,
            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
        refuse("compatibility_data_not_writable");
    __atomic_store_n(slot, replacement, __ATOMIC_RELEASE);
    if (mach_vm_protect(mach_task_self(), page, getpagesize(), false, regionInfo.protection) != KERN_SUCCESS)
        refuse("compatibility_data_protection_restore_failed");
    if (*slot != replacement) refuse("compatibility_data_readback_failed");
}

NSString* canonicalPath(NSString* path) {
    char result[PATH_MAX];
    if (!path || !realpath(path.fileSystemRepresentation, result)) return nil;
    return [NSString stringWithUTF8String:result];
}

bool imageMatches(const void* address, NSString* expected) {
    Dl_info image{};
    if (!address || !dladdr(address, &image) || !image.dli_fname) return false;
    NSString* found = canonicalPath([NSString stringWithUTF8String:image.dli_fname]);
    return found && [found isEqualToString:expected];
}

bool checkedImage(const char* label, const void* address, NSString* expected) {
    const bool matches = imageMatches(address, expected);
    if (!matches) {
        Dl_info image{};
        const bool resolved = address && dladdr(address, &image);
        const char* basename = resolved && image.dli_fname ? strrchr(image.dli_fname, '/') : nullptr;
        logLine("bridge_symbol_mismatch name=%s resolved=%d image=%s symbol=%s", label, resolved,
                basename ? basename + 1 : "unresolved", resolved && image.dli_sname ? image.dli_sname : "unavailable");
    }
    return matches;
}

bool hashMatches(NSString* path, const char* expected) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return false;
    struct stat status{};
    if (fstat(fd, &status) || !S_ISREG(status.st_mode)) { close(fd); return false; }
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[65536];
    ssize_t count;
    for (;;) {
        count = read(fd, buffer, sizeof(buffer));
        if (count > 0) CC_SHA256_Update(&context, buffer, static_cast<CC_LONG>(count));
        else if (count < 0 && errno == EINTR) continue;
        else break;
    }
    close(fd);
    if (count < 0) return false;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    char hexadecimal[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (size_t i = 0; i < sizeof(digest); ++i) snprintf(hexadecimal + 2 * i, 3, "%02x", digest[i]);
    return strcmp(hexadecimal, expected) == 0;
}

CFStringRef isolatedDomain(CFStringRef application) {
    if (active.load(std::memory_order_acquire) && application &&
        (CFEqual(application, kCFPreferencesCurrentApplication) ||
         CFEqual(application, CFSTR("com.apple.logic10")))) return preferenceDomain;
    return application;
}
CFPropertyListRef preferencesCopy(CFStringRef key, CFStringRef app) {
    return CFPreferencesCopyAppValue(key, isolatedDomain(app));
}
void preferencesSet(CFStringRef key, CFPropertyListRef value, CFStringRef app) {
    CFPreferencesSetAppValue(key, value, isolatedDomain(app));
}
Boolean preferencesBool(CFStringRef key, CFStringRef app, Boolean* valid) {
    CFStringRef domain = isolatedDomain(app);
    if (active.load(std::memory_order_acquire) && domain == preferenceDomain && key &&
        CFEqual(key, CFSTR("MAPrefs_ShowInProcessColumn"))) {
        if (valid) *valid = true;
        return true; // Enables the existing per-component IsForceInProcess branch.
    }
    return CFPreferencesGetAppBooleanValue(key, domain, valid);
}
CFIndex preferencesInteger(CFStringRef key, CFStringRef app, Boolean* valid) {
    return CFPreferencesGetAppIntegerValue(key, isolatedDomain(app), valid);
}
Boolean preferencesSynchronize(CFStringRef app, CFStringRef user, CFStringRef host) {
    return CFPreferencesSynchronize(isolatedDomain(app), user, host);
}
Boolean preferencesAppSynchronize(CFStringRef app) {
    return CFPreferencesAppSynchronize(isolatedDomain(app));
}
void preferencesSetValue(CFStringRef key, CFPropertyListRef value, CFStringRef app,
                         CFStringRef user, CFStringRef host) {
    CFPreferencesSetValue(key, value, isolatedDomain(app), user, host);
}
CFPropertyListRef preferencesCopyValue(CFStringRef key, CFStringRef app,
                                      CFStringRef user, CFStringRef host) {
    return CFPreferencesCopyValue(key, isolatedDomain(app), user, host);
}
CFDictionaryRef preferencesCopyMultiple(CFArrayRef keys, CFStringRef app,
                                        CFStringRef user, CFStringRef host) {
    return CFPreferencesCopyMultiple(keys, isolatedDomain(app), user, host);
}
void preferencesSetMultiple(CFDictionaryRef values, CFArrayRef removeKeys,
                            CFStringRef app, CFStringRef user, CFStringRef host) {
    CFPreferencesSetMultiple(values, removeKeys, isolatedDomain(app), user, host);
}
CFArrayRef preferencesCopyKeyList(CFStringRef app, CFStringRef user, CFStringRef host) {
    return CFPreferencesCopyKeyList(isolatedDomain(app), user, host);
}
id standardDefaults(id, SEL) { return isolatedDefaults; }

NSArray* (*originalRunningApplications)(id, SEL);
NSArray* runningApplications(id self, SEL selector) {
    NSArray* applications = originalRunningApplications(self, selector);
    return [applications filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
        ^BOOL(NSRunningApplication* app, NSDictionary*) {
            return app.processIdentifier == getpid() || ![app.bundleIdentifier isEqualToString:@"com.apple.logic10"];
        }]];
}
NSArray* (*originalRunningApplicationsForID)(id, SEL, NSString*);
NSArray* runningApplicationsForID(id self, SEL selector, NSString* bundleID) {
    NSArray* applications = originalRunningApplicationsForID(self, selector, bundleID);
    if (![bundleID isEqualToString:@"com.apple.logic10"]) return applications;
    return [applications filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
        ^BOOL(NSRunningApplication* app, NSDictionary*) { return app.processIdentifier == getpid(); }]];
}

// The exact MACore ABI is hash-gated below. A CMATagSet_plist key is held at
// +0x20; MAAudioEngine formats it as "%08x-%08x-%08x", type/subtype/manufacturer.
// Check the actual object's vtable before accessing this subclass field.
bool copyComponentKey(void* object, char (&text)[27]) {
    if (!object || !tagPlistVtable || *reinterpret_cast<void***>(object) != tagPlistVtable + 2) return false;
    CFStringRef key = *reinterpret_cast<CFStringRef*>(static_cast<unsigned char*>(object) + 0x20);
    if (!key || CFGetTypeID(key) != CFStringGetTypeID() || CFStringGetLength(key) != 26) return false;
    if (!CFStringGetCString(key, text, sizeof(text), kCFStringEncodingASCII) || text[8] != '-' || text[17] != '-') return false;
    for (size_t i = 0; i < 26; ++i) {
        if (i == 8 || i == 17) continue;
        if (!((text[i] >= '0' && text[i] <= '9') || (text[i] >= 'a' && text[i] <= 'f'))) return false;
    }
    return true;
}
pthread_mutex_t tagLogMutex = PTHREAD_MUTEX_INITIALIZER;
char loggedARAKeys[128][27];
size_t loggedARAKeyCount;
bool loggedNormalAU;
void logARAKeyOnce(const char* key) {
    bool newlySeen = true;
    pthread_mutex_lock(&tagLogMutex);
    for (size_t i = 0; i < loggedARAKeyCount; ++i) {
        if (strcmp(loggedARAKeys[i], key) == 0) { newlySeen = false; break; }
    }
    if (newlySeen && loggedARAKeyCount < 128) memcpy(loggedARAKeys[loggedARAKeyCount++], key, 27);
    else newlySeen = false;
    pthread_mutex_unlock(&tagLogMutex);
    if (newlySeen) logLine("ara_inprocess component_key=%s", key);
}
extern "C" bool originalForceInProcess(void*) asm("__ZN9CMATagSet16IsForceInProcessEv");
bool forceInProcess(void* tag) {
    char key[27]{};
    const bool knownKey = active.load(std::memory_order_acquire) && copyComponentKey(tag, key);
    if (knownKey && (memcmp(key, "6172616d-", 9) == 0 || memcmp(key, "61726178-", 9) == 0)) {
        logARAKeyOnce(key);
        return true;
    }
    const bool originalResult = originalForceInProcess(tag);
    if (knownKey && (memcmp(key, "61756678-", 9) == 0 || memcmp(key, "61756d66-", 9) == 0)) {
        pthread_mutex_lock(&tagLogMutex);
        const bool first = !loggedNormalAU;
        loggedNormalAU = true;
        pthread_mutex_unlock(&tagLogMutex);
        if (first) logLine("normal_au_passthrough component_key=%s original_force_inprocess=%d", key, originalResult);
    }
    return originalResult;
}

struct TemporaryAudioUnit {
    AudioUnit value = nullptr;
    ~TemporaryAudioUnit() { if (value) AudioComponentInstanceDispose(value); }
};

void setupNativeARA(void* object) {
    auto* bytes = static_cast<unsigned char*>(object);
    const uint32_t architecture = *reinterpret_cast<uint32_t*>(bytes + 0x1ec);
    const uint32_t type = *reinterpret_cast<uint32_t*>(bytes + 0x1e0);
    const bool selected = active.load(std::memory_order_acquire) &&
        nativeARASetupEnabled.load(std::memory_order_acquire) && architecture == kAUv2 && (type == kARAM || type == kARAX);
    TemporaryAudioUnit temporary;
    if (selected && *reinterpret_cast<uint32_t*>(bytes + 0x1f0) == 0) {
        temporary.value = createNativeAU(object);
        const void* factory = temporary.value ? getNativeFactory(object, temporary.value) : nullptr;
        *reinterpret_cast<const void**>(bytes + 0x1a8) = factory;
        *reinterpret_cast<uint32_t*>(bytes + 0x1f0) = factory ? 2 : 1;
        logLine("ara_discovery type=%08x subtype=%08x manufacturer=%08x factory_present=%d", type,
                *reinterpret_cast<uint32_t*>(bytes + 0x1e4), *reinterpret_cast<uint32_t*>(bytes + 0x1e8), factory != nullptr);
    }
    originalSetup(object);
    if (selected && *reinterpret_cast<void**>(bytes + 0x30) != nullptr) {
        // SetupSubClass builds this native interface table before creating the
        // ARA document. Clients retain its pointer for subsequent source reads.
        // Original setup has completed and owns this document. These guards
        // precede ALL bridge callback writes. Its void ABI provides no verified
        // failure return, and destroying that live object here is unsafe.
        // On mismatch leave the native document/factory/callback untouched,
        // disable future manual discovery, and visibly invalidate compatibility.
        if (!nativeARASetupEnabled.load(std::memory_order_acquire)) {
            reportRuntimeSetupFailure("setup_disabled_during_native_setup");
            return;
        }
        if (*reinterpret_cast<uint64_t*>(bytes + 0x48) != 32 ||
            *reinterpret_cast<void**>(bytes + 0x160) != bytes + 0x48) {
            reportRuntimeSetupFailure("source_reader_interface_layout_mismatch");
            return;
        }
        auto** slot = reinterpret_cast<void**>(bytes + 0x58);
        void* expected = reinterpret_cast<void*>(originalReadSamples);
        if (!__atomic_compare_exchange_n(slot, &expected, reinterpret_cast<void*>(readNativeSourceSamples),
                false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE) &&
            expected != reinterpret_cast<void*>(readNativeSourceSamples)) {
            // Failed compare/exchange writes nothing, including if another
            // native owner changed this slot after its initial observation.
            reportRuntimeSetupFailure("source_reader_callback_mismatch");
            return;
        }
    }
    if (selected) logLine("ara_setup type=%08x subtype=%08x manufacturer=%08x document_present=%d", type,
                          *reinterpret_cast<uint32_t*>(bytes + 0x1e4), *reinterpret_cast<uint32_t*>(bytes + 0x1e8),
                          *reinterpret_cast<void**>(bytes + 0x30) != nullptr);
}

void installWrapper(NSString* enginePath, NSString* corePath) {
    void* process = dlopen(nullptr, RTLD_NOW);
    auto** table = static_cast<void**>(dlsym(process, "_ZTV13ARA_Interface"));
    originalSetup = reinterpret_cast<SetupFn>(dlsym(process, "_ZN13ARA_Interface13SetupSubClassEv"));
    createNativeAU = reinterpret_cast<CreateAUFn>(dlsym(process, "_ZN13ARA_Interface32CreateV2AudioUnitForARAInterfaceEv"));
    getNativeFactory = reinterpret_cast<GetFactoryFn>(dlsym(process, "_ZN13ARA_Interface33Priv_GetARAFactoryFromV2AudioUnitEP23ComponentInstanceRecord"));
    tagPlistVtable = static_cast<void**>(dlsym(process, "_ZTV15CMATagSet_plist"));
    const void* forceTagSymbol = dlsym(process, "_ZN9CMATagSet16IsForceInProcessEv");
    // Evaluate every identity check, so a refusal identifies the observed mismatch.
    bool identitiesMatch = checkedImage("ARA_Interface_vtable", table, enginePath);
    identitiesMatch &= checkedImage("SetupSubClass", reinterpret_cast<void*>(originalSetup), enginePath);
    identitiesMatch &= checkedImage("CreateV2AudioUnit", reinterpret_cast<void*>(createNativeAU), enginePath);
    identitiesMatch &= checkedImage("GetARAFactory", reinterpret_cast<void*>(getNativeFactory), enginePath);
    identitiesMatch &= checkedImage("CMATagSet_plist_vtable", tagPlistVtable, corePath);
    // dlsym observes the installed interpose replacement. Calls made from this
    // interposing image to its imported original symbol retain dyld's original
    // call-through; verify that distinct pointer belongs to the qualified core.
    if (forceTagSymbol == reinterpret_cast<void*>(forceInProcess)) {
        logLine("bridge_interpose_resolved name=IsForceInProcess target=self");
    } else {
        identitiesMatch &= checkedImage("IsForceInProcess", forceTagSymbol, corePath);
    }
    identitiesMatch &= checkedImage("IsForceInProcess_callthrough", reinterpret_cast<void*>(originalForceInProcess), corePath);
    if (!identitiesMatch) refuse("loaded_image_or_vtable_mismatch");
    if (table[14] != reinterpret_cast<void*>(originalSetup)) refuse("setup_vtable_slot_mismatch");

    mach_vm_address_t address = reinterpret_cast<mach_vm_address_t>(&table[14]);
    mach_vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t regionInfo{};
    mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    if (mach_vm_region(mach_task_self(), &address, &regionSize, VM_REGION_BASIC_INFO_64,
                       reinterpret_cast<vm_region_info_t>(&regionInfo), &infoCount, &objectName) != KERN_SUCCESS)
        refuse("vtable_region_unavailable");
    if (objectName != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), objectName);
    const mach_vm_address_t page = reinterpret_cast<uintptr_t>(&table[14]) & ~(uintptr_t(getpagesize()) - 1);
    if (mach_vm_protect(mach_task_self(), page, getpagesize(), false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
        refuse("vtable_data_not_writable");
    __atomic_store_n(&table[14], reinterpret_cast<void*>(setupNativeARA), __ATOMIC_RELEASE);
    if (mach_vm_protect(mach_task_self(), page, getpagesize(), false, regionInfo.protection) != KERN_SUCCESS)
        refuse("vtable_protection_restore_failed");
    if (table[14] != reinterpret_cast<void*>(setupNativeARA)) refuse("vtable_readback_failed");

    {
        auto** sourceTable = static_cast<void**>(dlsym(process, "_ZTV15ARA_AudioSource"));
        auto** modeTable = static_cast<void**>(dlsym(process, "_ZTV8MDStream"));
        originalReadSamples = reinterpret_cast<ReadSamplesFn>(dlsym(process,
            "_ZN17ARA_HostInterface16ReadAudioSamplesEPN3ARA41ARAAudioAccessControllerHostRefMarkupTypeEPNS0_31ARAAudioReaderHostRefMarkupTypeExxPKPv"));
        Dl_info engineInfo{};
        if (!dladdr(reinterpret_cast<void*>(originalSetup), &engineInfo) || !engineInfo.dli_fbase)
            refuse("stereo_reader_engine_base_unavailable");
        const uintptr_t base = reinterpret_cast<uintptr_t>(engineInfo.dli_fbase);
        sourceVtable = sourceTable ? sourceTable + 2 : nullptr;
        streamVtable = modeTable ? modeTable + 2 : nullptr;
        regionEntryVtable = reinterpret_cast<void*>(base + 0xe3dc28);
        originalStreamMode = streamVtable ? reinterpret_cast<StreamModeFn>(streamVtable[20]) : nullptr;
        bool stereoIdentities = checkedImage("ARA_AudioSource_vtable", sourceVtable, enginePath);
        stereoIdentities &= checkedImage("MDStream_vtable", streamVtable, enginePath);
        stereoIdentities &= checkedImage("ARA_region_entry_vtable", regionEntryVtable, enginePath);
        stereoIdentities &= checkedImage("ReadAudioSamples", reinterpret_cast<void*>(originalReadSamples), enginePath);
        stereoIdentities &= checkedImage("MDStream_GetMode", reinterpret_cast<void*>(originalStreamMode), enginePath);
        if (!stereoIdentities || reinterpret_cast<uintptr_t>(sourceVtable) != base + 0xe35d50 ||
            reinterpret_cast<uintptr_t>(streamVtable) != base + 0xe34f58 ||
            reinterpret_cast<uintptr_t>(originalReadSamples) != base + 0x7b52a8 ||
            reinterpret_cast<uintptr_t>(originalStreamMode) != base + 0x70f8ac)
            refuse("stereo_reader_abi_mismatch");
        replaceDataPointer(streamVtable + 20, reinterpret_cast<void*>(originalStreamMode),
            reinterpret_cast<void*>(sourceReadStreamMode));
        logLine("ara_stereo_reader_ready scope=two_channel_source_reads stored_track_modes=preserved");
    }
}

void installProcessIsolation() {
    isolatedDefaults = [[NSUserDefaults alloc] initWithSuiteName:(__bridge NSString*)preferenceDomain];
    if (!isolatedDefaults) refuse("preferences_suite_unavailable");
    [isolatedDefaults setVolatileDomain:@{@"ApplePersistenceIgnoreState": @YES, @"NSQuitAlwaysKeepsWindows": @NO}
                              forName:NSArgumentDomain];
    Method defaults = class_getClassMethod([NSUserDefaults class], @selector(standardUserDefaults));
    Method applications = class_getInstanceMethod([NSWorkspace class], @selector(runningApplications));
    Method byID = class_getClassMethod([NSRunningApplication class], @selector(runningApplicationsWithBundleIdentifier:));
    if (!defaults || !applications || !byID) refuse("isolation_method_unavailable");
    method_setImplementation(defaults, reinterpret_cast<IMP>(standardDefaults));
    originalRunningApplications = reinterpret_cast<NSArray*(*)(id, SEL)>(method_setImplementation(applications, reinterpret_cast<IMP>(runningApplications)));
    originalRunningApplicationsForID = reinterpret_cast<NSArray*(*)(id, SEL, NSString*)>(method_setImplementation(byID, reinterpret_cast<IMP>(runningApplicationsForID)));
}

NSString* requestedProject;
id launchObserver;
bool projectRequestScheduled;

void requestProjectOpenOnMainQueue() {
    // This function is only dispatched to the main queue. Document-controller
    // access is read-only: opening through its NSDocument API does not establish
    // Logic's live song, so delivery uses the normal odoc Apple Event instead.
    if (projectRequestScheduled || !requestedProject) return;
    projectRequestScheduled = true;
    if (launchObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:launchObserver];
        launchObserver = nil;
    }
    for (NSDocument* document in [NSDocumentController sharedDocumentController].documents) {
        NSURL* url = document.fileURL;
        if (url.isFileURL && [canonicalPath(url.path) isEqualToString:requestedProject]) {
            logLine("odoc_skipped reason=project_already_open");
            return;
        }
    }
    NSURL* projectURL = [NSURL fileURLWithPath:requestedProject];
    logLine("odoc_requested target_pid=%d", getpid());
    // An Apple Event addressed to this process can synchronously invoke AppKit
    // on the sending thread. Sending off-main caused a verified Swift MainActor
    // assertion in Logic's launch path; the send must stay on this main queue.
    NSAppleEventDescriptor* target = [NSAppleEventDescriptor descriptorWithProcessIdentifier:getpid()];
    NSAppleEventDescriptor* event = [NSAppleEventDescriptor appleEventWithEventClass:kCoreEventClass
        eventID:kAEOpenDocuments targetDescriptor:target returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    NSAppleEventDescriptor* list = [NSAppleEventDescriptor listDescriptor];
    [list insertDescriptor:[NSAppleEventDescriptor descriptorWithFileURL:projectURL] atIndex:0];
    [event setParamDescriptor:list forKeyword:keyDirectObject];
    // A self-send may wait for the main loop to receive the queued event. Keep
    // that wait to one second; a timeout is delivery status, never a retry.
    const OSStatus status = AESendMessage(event.aeDesc, nullptr, kAENoReply, 60);
    // A delivery result (including a timeout) is not proof that the song opened.
    // Do not resend: a timed-out event can still be handled after this returns.
    logLine("odoc_status code=%d delivery_only=1", static_cast<int>(status));
}

void prepareExplicitProjectRequest() {
    const char* value = getenv("LOGIC_ARA_PROJECT_PATH");
    if (!value || !*value) return;
    NSString* supplied = [NSString stringWithUTF8String:value];
    if (!supplied.isAbsolutePath || ![supplied.pathExtension.lowercaseString isEqualToString:@"logicx"])
        refuse("project_path_must_be_absolute_logicx");
    requestedProject = canonicalPath(supplied);
    struct stat status{};
    if (!requestedProject || stat(requestedProject.fileSystemRepresentation, &status) ||
        (!S_ISDIR(status.st_mode) && !S_ISREG(status.st_mode)) ||
        ![requestedProject.pathExtension.lowercaseString isEqualToString:@"logicx"])
        refuse("project_path_unavailable");
    launchObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
        object:nil queue:nil usingBlock:^(NSNotification*) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                requestProjectOpenOnMainQueue();
            });
        }];
    // DYLD injection registers before launch finishes. NSApp.running is not a
    // valid substitute for the finish notification and must not trigger an open.
}
} // namespace

#if !defined(LOGIC_ARA_BRIDGE_TEST)
#define INTERPOSE(name, replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) static const struct { const void* replacement; const void* original; } name = \
        { reinterpret_cast<const void*>(replacement), reinterpret_cast<const void*>(original) }
INTERPOSE(copyAppValueHook, preferencesCopy, CFPreferencesCopyAppValue);
INTERPOSE(setAppValueHook, preferencesSet, CFPreferencesSetAppValue);
INTERPOSE(booleanHook, preferencesBool, CFPreferencesGetAppBooleanValue);
INTERPOSE(integerHook, preferencesInteger, CFPreferencesGetAppIntegerValue);
INTERPOSE(synchronizeHook, preferencesSynchronize, CFPreferencesSynchronize);
INTERPOSE(appSynchronizeHook, preferencesAppSynchronize, CFPreferencesAppSynchronize);
INTERPOSE(setValueHook, preferencesSetValue, CFPreferencesSetValue);
INTERPOSE(copyValueHook, preferencesCopyValue, CFPreferencesCopyValue);
INTERPOSE(copyMultipleHook, preferencesCopyMultiple, CFPreferencesCopyMultiple);
INTERPOSE(setMultipleHook, preferencesSetMultiple, CFPreferencesSetMultiple);
INTERPOSE(keyListHook, preferencesCopyKeyList, CFPreferencesCopyKeyList);
INTERPOSE(forceInProcessHook, forceInProcess, originalForceInProcess);

__attribute__((constructor)) static void startBridge() { @autoreleasepool {
    // Do not propagate injection to plug-in helpers, tools or later child apps.
    unsetenv("DYLD_INSERT_LIBRARIES");
    const char* appValue = getenv("LOGIC_ARA_APP_PATH");
    const char* logValue = getenv("LOGIC_ARA_LOG_PATH");
    const char* domainValue = getenv("LOGIC_ARA_PREFERENCES_DOMAIN");
    const char* parentValue = getenv("LOGIC_ARA_PARENT_PID");
    if (!appValue || !logValue || !domainValue || !parentValue || atoi(parentValue) != getppid()) return;
    char executableBuffer[PATH_MAX];
    uint32_t executableSize = sizeof(executableBuffer);
    if (_NSGetExecutablePath(executableBuffer, &executableSize)) return;
    NSString* app = canonicalPath([NSString stringWithUTF8String:appValue]);
    NSString* executable = canonicalPath([NSString stringWithUTF8String:executableBuffer]);
    NSString* expectedExecutable = canonicalPath([app stringByAppendingPathComponent:@"Contents/MacOS/Logic Pro"]);
    if (!app || !executable || !expectedExecutable || ![executable isEqualToString:expectedExecutable]) return;

    int logFD = open(logValue, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0600);
    struct stat logStatus{};
    if (logFD < 0 || fstat(logFD, &logStatus) || !S_ISREG(logStatus.st_mode) || logStatus.st_uid != getuid()) {
        if (logFD >= 0) close(logFD);
        _exit(78);
    }
    logFile = fdopen(logFD, "a");
    if (!logFile) { close(logFD); _exit(78); }
    if ([app isEqualToString:@"/Applications/Logic Pro.app"]) refuse("installed_app_is_not_a_private_copy");
    NSString* domain = [NSString stringWithUTF8String:domainValue];
    NSString* baseDomain = @"org.rysupaudio.logic-ara-launcher";
    NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"] invertedSet];
    if ((! [domain isEqualToString:baseDomain] && ![domain hasPrefix:[baseDomain stringByAppendingString:@"."]]) ||
        [domain rangeOfCharacterFromSet:invalid].location != NSNotFound) refuse("preferences_domain_rejected");
    NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"]];
    if (![info[@"CFBundleIdentifier"] isEqualToString:@"com.apple.logic10"] ||
        ![info[@"CFBundleShortVersionString"] isEqualToString:@"12.4"] ||
        ![info[@"CFBundleVersion"] isEqualToString:@"6707"]) refuse("unsupported_logic_build");
    int translated = 0;
    size_t translatedSize = sizeof(translated);
    if ((sysctlbyname("sysctl.proc_translated", &translated, &translatedSize, nullptr, 0) != 0 && errno != ENOENT) || translated)
        refuse("native_arm64_required");
    NSString* engine = canonicalPath([app stringByAppendingPathComponent:[NSString stringWithUTF8String:kEngineRelative]]);
    NSString* core = canonicalPath([app stringByAppendingPathComponent:[NSString stringWithUTF8String:kCoreRelative]]);
    NSString* bundlePrefix = [app stringByAppendingString:@"/"];
    if (!engine || !core || ![engine hasPrefix:bundlePrefix] || ![core hasPrefix:bundlePrefix] ||
        !hashMatches(engine, kEngineSHA256) || !hashMatches(core, kCoreSHA256)) refuse("framework_hash_or_path_mismatch");
    preferenceDomain = static_cast<CFStringRef>(CFRetain((__bridge CFStringRef)domain));
    active.store(true, std::memory_order_release);
    installProcessIsolation();
    installWrapper(engine, core);
    prepareExplicitProjectRequest();
    logLine("bridge_ready version=12.4 build=6707 architecture=arm64 hosting=ara_only preferences=%s", domainValue);
} }
#endif
