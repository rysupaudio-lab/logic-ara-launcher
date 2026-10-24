// Runtime-only compatibility bridge for the exact Logic 12.4 (6707) ABI.
// The launcher must start a verified private copy. No Apple file is written here.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Carbon/Carbon.h>
#import <objc/runtime.h>
#import <objc/message.h>
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
#include <array>
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
NSUserDefaults* capturedStandardDefaults;
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

#if defined(LOGIC_ARA_BRIDGE_TEST)
// Unit tests use a disposable synthetic domain, never the user's Logic domain.
CFStringRef testLogicPreferencesDomain = CFSTR("org.rysupaudio.logic-ara-test.original");
#endif
CFStringRef logicPreferencesDomain() {
#if defined(LOGIC_ARA_BRIDGE_TEST)
    return testLogicPreferencesDomain;
#else
    return CFSTR("com.apple.logic10");
#endif
}
CFStringRef isolatedDomain(CFStringRef application) {
    if (active.load(std::memory_order_acquire) && application &&
        (CFEqual(application, kCFPreferencesCurrentApplication) ||
         CFEqual(application, logicPreferencesDomain()))) return preferenceDomain;
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

// Foundation/AppKit can use private, container-aware preferences calls that do
// not traverse dyld's public CFPreferences interposes. Pin their actual runtime
// Objective-C signatures and owning image before installing these boundaries.
// Every wrapper changes only the exact current/Logic identifier. Containers,
// configuration URLs, users, hosts and unrelated preference domains survive.
using DefaultsIdentifierFn = CFStringRef (*)(id, SEL);
DefaultsIdentifierFn nativeDefaultsIdentifier;
SEL nativeDefaultsIdentifierSelector;
using PrefsSetAppFn = void (*)(id, SEL, CFPropertyListRef, CFStringRef, CFStringRef, CFStringRef, CFURLRef);
using PrefsCopyAppFn = CFPropertyListRef (*)(id, SEL, CFStringRef, CFStringRef, CFStringRef, CFURLRef);
using PrefsCopyValueFn = CFPropertyListRef (*)(id, SEL, CFStringRef, CFStringRef, CFStringRef, CFStringRef, CFStringRef);
PrefsSetAppFn originalPrefsSetApp;
PrefsCopyAppFn originalPrefsCopyApp;
PrefsCopyValueFn originalPrefsCopyValue;
std::atomic<unsigned> navigationPreferenceTraces{0};

CFStringRef defaultsIdentifier(id object) {
    return nativeDefaultsIdentifier && [object isKindOfClass:[NSUserDefaults class]] ?
        nativeDefaultsIdentifier(object, nativeDefaultsIdentifierSelector) : nullptr;
}
void traceNavigationPreference(const char* api, CFStringRef key, id receiver,
        CFStringRef identifier, const void* caller) {
    if (!active.load(std::memory_order_acquire) || !key || !logFile ||
        (!CFEqual(key, CFSTR("NSOSPLastRootDirectory")) && !CFEqual(key, CFSTR("NSWindow Frame GoToSheet")))) return;
    if (navigationPreferenceTraces.fetch_add(1, std::memory_order_relaxed) >= 64) return;
    char name[64]{};
    CFStringGetCString(key, name, sizeof(name), kCFStringEncodingASCII);
    const char* domain = !identifier ? "nil" :
        CFEqual(identifier, preferenceDomain) ? "private" :
        isolatedDomain(identifier) == preferenceDomain ? "logic" : "other";
    Dl_info image{}; dladdr(caller, &image);
    const char* basename = image.dli_fname ? strrchr(image.dli_fname, '/') : nullptr;
    logLine("preferences_navigation_write api=%s key=\"%s\" receiver=%s class=%s domain=%s caller_image=%s caller_symbol=\"%s\" values_omitted=1",
        api, name, receiver == capturedStandardDefaults ? "captured_standard" : receiver == isolatedDefaults ? "private_suite" : "other",
        receiver ? object_getClassName(receiver) : "nil", domain,
        basename ? basename + 1 : "unknown", image.dli_sname ? image.dli_sname : "unknown");
}
void prefsSetAppValue(id self, SEL selector, CFPropertyListRef value, CFStringRef key,
        CFStringRef identifier, CFStringRef container, CFURLRef configuration) {
    traceNavigationPreference("CFXPreferences", key, self, identifier, __builtin_return_address(0));
    originalPrefsSetApp(self, selector, value, key, isolatedDomain(identifier), container, configuration);
}
CFPropertyListRef prefsCopyAppValue(id self, SEL selector, CFStringRef key,
        CFStringRef identifier, CFStringRef container, CFURLRef configuration) {
    return originalPrefsCopyApp(self, selector, key, isolatedDomain(identifier), container, configuration);
}
CFPropertyListRef prefsCopyValue(id self, SEL selector, CFStringRef key, CFStringRef identifier,
        CFStringRef user, CFStringRef host, CFStringRef container) {
    return originalPrefsCopyValue(self, selector, key, isolatedDomain(identifier), user, host, container);
}
struct CorePreferencesOperation {
    const char* name; const char* encoding; IMP replacement; Method method; IMP original;
};
CorePreferencesOperation corePreferencesOperations[] = {
    {"setValue:forKey:appIdentifier:container:configurationURL:",
        "v56@0:8^v16^{__CFString=}24^{__CFString=}32^{__CFString=}40^{__CFURL=}48", reinterpret_cast<IMP>(prefsSetAppValue), nullptr, nullptr},
    {"copyAppValueForKey:identifier:container:configurationURL:",
        "^v48@0:8^{__CFString=}16^{__CFString=}24^{__CFString=}32^{__CFURL=}40", reinterpret_cast<IMP>(prefsCopyAppValue), nullptr, nullptr},
    {"copyValueForKey:identifier:user:host:container:",
        "^v56@0:8^{__CFString=}16^{__CFString=}24^{__CFString=}32^{__CFString=}40^{__CFString=}48", reinterpret_cast<IMP>(prefsCopyValue), nullptr, nullptr}
};
bool corePreferencesMethodMatches(Method method, const char* encoding) {
    Dl_info image{};
    return method && strcmp(method_getTypeEncoding(method), encoding) == 0 &&
        dladdr(reinterpret_cast<void*>(method_getImplementation(method)), &image) && image.dli_fname &&
        strcmp(image.dli_fname, "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation") == 0;
}
void installCorePreferencesIsolation() {
    Class preferences = NSClassFromString(@"_CFXPreferences");
    nativeDefaultsIdentifierSelector = sel_registerName("_identifier");
    Method identifier = class_getInstanceMethod([NSUserDefaults class], nativeDefaultsIdentifierSelector);
    if (!preferences || !corePreferencesMethodMatches(identifier, "^{__CFString=}16@0:8"))
        refuse("preferences_identifier_abi_unqualified");
    for (auto& operation : corePreferencesOperations) {
        operation.method = class_getInstanceMethod(preferences, sel_registerName(operation.name));
        if (!corePreferencesMethodMatches(operation.method, operation.encoding))
            refuse("preferences_container_abi_unqualified");
        operation.original = method_getImplementation(operation.method);
    }
    nativeDefaultsIdentifier = reinterpret_cast<DefaultsIdentifierFn>(method_getImplementation(identifier));
    originalPrefsSetApp = reinterpret_cast<PrefsSetAppFn>(corePreferencesOperations[0].original);
    originalPrefsCopyApp = reinterpret_cast<PrefsCopyAppFn>(corePreferencesOperations[1].original);
    originalPrefsCopyValue = reinterpret_cast<PrefsCopyValueFn>(corePreferencesOperations[2].original);
    for (const auto& operation : corePreferencesOperations)
        method_setImplementation(operation.method, operation.replacement);
    logLine("preferences_container_boundary_ready methods=3 identifier_getter_verified=1 other_domains_preserved=1");
}

// AppKit may retain the original standard object before our constructor runs.
// Changing only +standardUserDefaults does not redirect those cached receivers.
// Override public NSUserDefaults operations, forwarding only that exact object
// to the private suite. Other receivers retain their original implementation.
// Explicit Logic domain names are redirected; unrelated suites/global domains
// are passed through. No private NSUserDefaults ivar or CF object is modified.
struct DefaultsOperation { const char* name; IMP replacement; SEL selector; IMP original; Method method; };
IMP originalDefaultsOperation(SEL selector);
id defaultsReceiver(id self) {
    if (!active.load(std::memory_order_acquire)) return self;
    if (self == capturedStandardDefaults) return isolatedDefaults;
    CFStringRef identifier = defaultsIdentifier(self);
    return identifier && isolatedDomain(identifier) == preferenceDomain ? isolatedDefaults : self;
}
NSString* defaultsDomainName(NSString* name) {
    return name ? (__bridge NSString*)isolatedDomain((__bridge CFStringRef)name) : nil;
}

#define DEFAULTS_KEY_GETTER(function, type) \
type function(id self, SEL selector, NSString* key) { \
    id target = defaultsReceiver(self); \
    using Call = type (*)(id, SEL, NSString*); \
    return target != self ? reinterpret_cast<Call>(objc_msgSend)(target, selector, key) : \
        reinterpret_cast<Call>(originalDefaultsOperation(selector))(self, selector, key); \
}
DEFAULTS_KEY_GETTER(defaultsObjectForKey, id)
DEFAULTS_KEY_GETTER(defaultsIntegerForKey, NSInteger)
DEFAULTS_KEY_GETTER(defaultsFloatForKey, float)
DEFAULTS_KEY_GETTER(defaultsDoubleForKey, double)
DEFAULTS_KEY_GETTER(defaultsBoolForKey, BOOL)
#undef DEFAULTS_KEY_GETTER
#define DEFAULTS_KEY_SETTER(function, type) \
void function(id self, SEL selector, type value, NSString* key) { \
    traceNavigationPreference(sel_getName(selector), (__bridge CFStringRef)key, self, defaultsIdentifier(self), __builtin_return_address(0)); \
    id target = defaultsReceiver(self); \
    using Call = void (*)(id, SEL, type, NSString*); \
    if (target != self) reinterpret_cast<Call>(objc_msgSend)(target, selector, value, key); \
    else reinterpret_cast<Call>(originalDefaultsOperation(selector))(self, selector, value, key); \
}
DEFAULTS_KEY_SETTER(defaultsSetObject, id)
DEFAULTS_KEY_SETTER(defaultsSetInteger, NSInteger)
DEFAULTS_KEY_SETTER(defaultsSetFloat, float)
DEFAULTS_KEY_SETTER(defaultsSetDouble, double)
DEFAULTS_KEY_SETTER(defaultsSetBool, BOOL)
#undef DEFAULTS_KEY_SETTER
void defaultsOneObject(id self, SEL selector, id value) {
    id target = defaultsReceiver(self);
    using Call = void (*)(id, SEL, id);
    if (target != self) reinterpret_cast<Call>(objc_msgSend)(target, selector, value);
    else reinterpret_cast<Call>(originalDefaultsOperation(selector))(self, selector, value);
}
id defaultsRepresentation(id self, SEL selector) {
    id target = defaultsReceiver(self);
    using Call = id (*)(id, SEL);
    return target != self ? reinterpret_cast<Call>(objc_msgSend)(target, selector) :
        reinterpret_cast<Call>(originalDefaultsOperation(selector))(self, selector);
}
BOOL defaultsSynchronize(id self, SEL selector) {
    id target = defaultsReceiver(self);
    using Call = BOOL (*)(id, SEL);
    return target != self ? reinterpret_cast<Call>(objc_msgSend)(target, selector) :
        reinterpret_cast<Call>(originalDefaultsOperation(selector))(self, selector);
}
id defaultsDomainForName(id self, SEL selector, NSString* name) {
    id target = defaultsReceiver(self);
    using Call = id (*)(id, SEL, NSString*);
    name = defaultsDomainName(name);
    return target != self ? reinterpret_cast<Call>(objc_msgSend)(target, selector, name) :
        reinterpret_cast<Call>(originalDefaultsOperation(selector))(self, selector, name);
}
void defaultsNamedDomain(id self, SEL selector, NSString* name) {
    id target = defaultsReceiver(self);
    using Call = void (*)(id, SEL, NSString*);
    name = defaultsDomainName(name);
    if (target != self) reinterpret_cast<Call>(objc_msgSend)(target, selector, name);
    else reinterpret_cast<Call>(originalDefaultsOperation(selector))(self, selector, name);
}
void defaultsSetDomain(id self, SEL selector, NSDictionary* value, NSString* name) {
    id target = defaultsReceiver(self);
    using Call = void (*)(id, SEL, NSDictionary*, NSString*);
    name = defaultsDomainName(name);
    if (target != self) reinterpret_cast<Call>(objc_msgSend)(target, selector, value, name);
    else reinterpret_cast<Call>(originalDefaultsOperation(selector))(self, selector, value, name);
}
void defaultsSetObjectInDomain(id self, SEL selector, id value, NSString* key, NSString* domain) {
    traceNavigationPreference(sel_getName(selector), (__bridge CFStringRef)key, self,
        (__bridge CFStringRef)domain, __builtin_return_address(0));
    id target = defaultsReceiver(self);
    using Call = void (*)(id, SEL, id, NSString*, NSString*);
    domain = defaultsDomainName(domain);
    if (target != self) reinterpret_cast<Call>(objc_msgSend)(target, selector, value, key, domain);
    else reinterpret_cast<Call>(originalDefaultsOperation(selector))(self, selector, value, key, domain);
}
BOOL defaultsForcedInDomain(id self, SEL selector, NSString* key, NSString* name) {
    id target = defaultsReceiver(self);
    using Call = BOOL (*)(id, SEL, NSString*, NSString*);
    name = defaultsDomainName(name);
    return target != self ? reinterpret_cast<Call>(objc_msgSend)(target, selector, key, name) :
        reinterpret_cast<Call>(originalDefaultsOperation(selector))(self, selector, key, name);
}
#define DEFAULTS_OPERATION(selector, function) {selector, reinterpret_cast<IMP>(function), nullptr, nullptr, nullptr}
DefaultsOperation defaultsOperations[] = {
    DEFAULTS_OPERATION("objectForKey:", defaultsObjectForKey),
    DEFAULTS_OPERATION("stringForKey:", defaultsObjectForKey),
    DEFAULTS_OPERATION("arrayForKey:", defaultsObjectForKey),
    DEFAULTS_OPERATION("dictionaryForKey:", defaultsObjectForKey),
    DEFAULTS_OPERATION("dataForKey:", defaultsObjectForKey),
    DEFAULTS_OPERATION("stringArrayForKey:", defaultsObjectForKey),
    DEFAULTS_OPERATION("URLForKey:", defaultsObjectForKey),
    DEFAULTS_OPERATION("valueForKey:", defaultsObjectForKey),
    DEFAULTS_OPERATION("integerForKey:", defaultsIntegerForKey),
    DEFAULTS_OPERATION("floatForKey:", defaultsFloatForKey),
    DEFAULTS_OPERATION("doubleForKey:", defaultsDoubleForKey),
    DEFAULTS_OPERATION("boolForKey:", defaultsBoolForKey),
    DEFAULTS_OPERATION("objectIsForcedForKey:", defaultsBoolForKey),
    DEFAULTS_OPERATION("setObject:forKey:", defaultsSetObject),
    DEFAULTS_OPERATION("setObject:forKey:inDomain:", defaultsSetObjectInDomain),
    DEFAULTS_OPERATION("setValue:forKey:", defaultsSetObject),
    DEFAULTS_OPERATION("setURL:forKey:", defaultsSetObject),
    DEFAULTS_OPERATION("setInteger:forKey:", defaultsSetInteger),
    DEFAULTS_OPERATION("setFloat:forKey:", defaultsSetFloat),
    DEFAULTS_OPERATION("setDouble:forKey:", defaultsSetDouble),
    DEFAULTS_OPERATION("setBool:forKey:", defaultsSetBool),
    DEFAULTS_OPERATION("removeObjectForKey:", defaultsOneObject),
    DEFAULTS_OPERATION("registerDefaults:", defaultsOneObject),
    DEFAULTS_OPERATION("dictionaryRepresentation", defaultsRepresentation),
    DEFAULTS_OPERATION("volatileDomainNames", defaultsRepresentation),
    DEFAULTS_OPERATION("persistentDomainNames", defaultsRepresentation),
    DEFAULTS_OPERATION("synchronize", defaultsSynchronize),
    DEFAULTS_OPERATION("persistentDomainForName:", defaultsDomainForName),
    DEFAULTS_OPERATION("volatileDomainForName:", defaultsDomainForName),
    DEFAULTS_OPERATION("setPersistentDomain:forName:", defaultsSetDomain),
    DEFAULTS_OPERATION("setVolatileDomain:forName:", defaultsSetDomain),
    DEFAULTS_OPERATION("removePersistentDomainForName:", defaultsNamedDomain),
    DEFAULTS_OPERATION("removeVolatileDomainForName:", defaultsNamedDomain),
    DEFAULTS_OPERATION("addSuiteNamed:", defaultsNamedDomain),
    DEFAULTS_OPERATION("removeSuiteNamed:", defaultsNamedDomain),
    DEFAULTS_OPERATION("objectIsForcedForKey:inDomain:", defaultsForcedInDomain)
};
#undef DEFAULTS_OPERATION
IMP originalDefaultsOperation(SEL selector) {
    for (const auto& operation : defaultsOperations) if (operation.selector == selector) return operation.original;
    return nullptr; // Only exact installed selectors can enter these functions.
}
void installDefaultsInstanceIsolation() {
    Class base = [NSUserDefaults class];
    if (!capturedStandardDefaults || !isolatedDefaults || capturedStandardDefaults == isolatedDefaults)
        refuse("cached_defaults_identity_unavailable");
    // Validate every selector before changing any dispatch. Unrecognized
    // Foundation subclasses must fail before ordinary app use, not half-install.
    for (auto& operation : defaultsOperations) {
        operation.selector = sel_registerName(operation.name);
        operation.method = class_getInstanceMethod(base, operation.selector);
        if (!operation.method) refuse("defaults_operation_unavailable");
        operation.original = method_getImplementation(operation.method);
        if (strcmp(operation.name, "setObject:forKey:inDomain:") == 0 &&
            strcmp(method_getTypeEncoding(operation.method), "v40@0:8@16@24@32") != 0)
            refuse("defaults_named_setter_abi_unqualified");
        if (class_getMethodImplementation(object_getClass(capturedStandardDefaults), operation.selector) != operation.original)
            refuse("cached_defaults_override_unqualified");
    }
    for (auto& operation : defaultsOperations) {
        // Add an override when an API (e.g. KVC) was inherited; never alter an
        // NSObject method used by unrelated classes in the process.
        if (!class_addMethod(base, operation.selector, operation.replacement, method_getTypeEncoding(operation.method)))
            method_setImplementation(class_getInstanceMethod(base, operation.selector), operation.replacement);
    }
    logLine("preferences_cached_standard_redirected methods=%zu explicit_logic_domains=1 other_receivers_preserved=1", sizeof(defaultsOperations) / sizeof(defaultsOperations[0]));
}

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

void installPrivatePreferenceArguments() {
    // AppKit's native _createPanel: mode-zero factory consults this existing
    // config key through _NSGetBoolAppConfig. Keep open/save panels local so
    // their navigation preferences use this process's isolated defaults,
    // rather than the XPC panel service masquerading as the original bundle.
    // The launcher also passes the same argument before framework startup to
    // cover an AppKit config cache initialized before this constructor.
    // NSArgumentDomain is shared within this process, including explicit
    // suites. Preserve launch/framework arguments instead of replacing them.
    NSMutableDictionary* arguments = [[isolatedDefaults volatileDomainForName:NSArgumentDomain] mutableCopy];
    if (!arguments) arguments = [[NSMutableDictionary alloc] init];
    arguments[@"ApplePersistenceIgnoreState"] = @YES;
    arguments[@"NSQuitAlwaysKeepsWindows"] = @NO;
    arguments[@"NSUseRemoteSavePanel"] = @NO;
    [isolatedDefaults setVolatileDomain:arguments forName:NSArgumentDomain];
}

using RemotePanelConfigFn = bool (*)();
RemotePanelConfigFn nativeRemotePanelConfig() {
    // In this AppKit ABI, +_createPanel: mode 0 calls NSUseRemoteSavePanel;
    // false selects the existing NSLocalOpenPanel/NSLocalSavePanel route.
    // Read only the factory's bounded call window; never call the factory or
    // patch its dispatch, bundle identity, security token or native code.
    Method factory = class_getClassMethod(NSClassFromString(@"NSSavePanel"), sel_registerName("_createPanel:"));
    Dl_info factoryImage{};
    if (!factory || strcmp(method_getTypeEncoding(factory), "@20@0:8i16") != 0 ||
        !dladdr(reinterpret_cast<void*>(method_getImplementation(factory)), &factoryImage) || !factoryImage.dli_fname ||
        strcmp(factoryImage.dli_fname, "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit") != 0)
        return nullptr;
    RemotePanelConfigFn result = nullptr;
    const uintptr_t begin = reinterpret_cast<uintptr_t>(method_getImplementation(factory));
    std::array<uint32_t, 0x180 / sizeof(uint32_t)> instructions{};
    if (!readSelf(begin, instructions)) return nullptr;
    // This window includes the proven mode-zero false branch and native local
    // class selection. A future AppKit layout must be reviewed, not inferred
    // from the private selector/function names alone.
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(instructions.data(), sizeof(instructions), digest);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (size_t i = 0; i < sizeof(digest); ++i) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    if (strcmp(hex, "487faa2a1d6b1c576b3fd8e09d52b89de34f4e2cbe518dc1a604c3d6ac784958") != 0) return nullptr;
    for (uintptr_t offset = 0; offset < sizeof(instructions); offset += 4) {
        const uint32_t instruction = instructions[offset / 4];
        if ((instruction & 0xfc000000) != 0x94000000) continue; // AArch64 BL
        int64_t displacement = instruction & 0x03ffffff;
        if (displacement & 0x02000000) displacement -= 0x04000000;
        const uintptr_t target = static_cast<uintptr_t>(static_cast<int64_t>(begin + offset) + displacement * 4);
        Dl_info targetImage{};
        if (!dladdr(reinterpret_cast<void*>(target), &targetImage) || !targetImage.dli_sname ||
            strcmp(targetImage.dli_sname, "NSUseRemoteSavePanel") != 0) continue;
        if (targetImage.dli_saddr != reinterpret_cast<void*>(target) || !targetImage.dli_fname ||
            strcmp(targetImage.dli_fname, factoryImage.dli_fname) != 0) return nullptr;
        auto function = reinterpret_cast<RemotePanelConfigFn>(target);
        if (result && result != function) return nullptr;
        result = function;
    }
    return result;
}
bool verifyNativeLocalPanelConfig() {
    // The known present private argument avoids the native default-value
    // function. This getter only reads/caches config; it creates no panel/app.
    id requested = [isolatedDefaults objectForKey:@"NSUseRemoteSavePanel"];
    if (![requested isKindOfClass:[NSNumber class]] || [requested boolValue]) return false;
    RemotePanelConfigFn config = nativeRemotePanelConfig();
    if (!config || config()) return false;
    logLine("panel_preferences_route_ready remote=0 native_gate=NSUseRemoteSavePanel factory_mode=0 local_mode=1 panel_created=0");
    return true;
}

void installProcessIsolation() {
    capturedStandardDefaults = [NSUserDefaults standardUserDefaults];
    isolatedDefaults = [[NSUserDefaults alloc] initWithSuiteName:(__bridge NSString*)preferenceDomain];
    if (!isolatedDefaults) refuse("preferences_suite_unavailable");
    installPrivatePreferenceArguments();
    Method defaults = class_getClassMethod([NSUserDefaults class], @selector(standardUserDefaults));
    Method applications = class_getInstanceMethod([NSWorkspace class], @selector(runningApplications));
    Method byID = class_getClassMethod([NSRunningApplication class], @selector(runningApplicationsWithBundleIdentifier:));
    if (!defaults || !applications || !byID) refuse("isolation_method_unavailable");
    installCorePreferencesIsolation();
    installDefaultsInstanceIsolation();
    method_setImplementation(defaults, reinterpret_cast<IMP>(standardDefaults));
    if (!verifyNativeLocalPanelConfig()) refuse("native_local_panel_configuration_unqualified");
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
