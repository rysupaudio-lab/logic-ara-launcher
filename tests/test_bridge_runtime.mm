// Offline guard tests: execute the actual bridge setup wrapper with a fake
// native setup callback and owned byte arrays. Never load Logic or a plug-in.
#define LOGIC_ARA_BRIDGE_TEST 1
#include "../native/Bridge.mm"
#include <array>

namespace {
extern "C" bool originalForceInProcess(void*) { return false; }
enum class Case { Valid, AlreadyWrapped, BadSize, BadInterface, BadCallback, NoDocument, DisabledDuringSetup };
Case nextCase = Case::Valid;
unsigned setupCalls = 0, createCalls = 0, factoryCalls = 0, checks = 0;
std::array<unsigned char, 0x238> nativeCompleted{};
int documentToken, factoryToken, otherCallbackToken, wrongInterfaceToken;
int32_t fakeRead(void*, void*, int64_t, int64_t, void* const*) { return 0; }
AudioUnit fakeCreate(void*) { ++createCalls; return nullptr; }
const void* fakeFactory(void*, AudioUnit) { ++factoryCalls; return nullptr; }
void check(bool value, const char* message) {
    ++checks;
    if (!value) { fprintf(stderr, "FAIL: %s\n", message); std::abort(); }
}
void fakeSetup(void* object) {
    ++setupCalls;
    auto* b = static_cast<unsigned char*>(object);
    *reinterpret_cast<void**>(b + 0x30) = nextCase == Case::NoDocument ? nullptr : &documentToken;
    *reinterpret_cast<uint64_t*>(b + 0x48) = nextCase == Case::BadSize ? 31 : 32;
    *reinterpret_cast<void**>(b + 0x160) = nextCase == Case::BadInterface ? static_cast<void*>(&wrongInterfaceToken) : static_cast<void*>(b + 0x48);
    *reinterpret_cast<void**>(b + 0x58) = nextCase == Case::BadCallback ? &otherCallbackToken :
        nextCase == Case::AlreadyWrapped ? reinterpret_cast<void*>(readNativeSourceSamples) : reinterpret_cast<void*>(fakeRead);
    if (nextCase == Case::DisabledDuringSetup) nativeARASetupEnabled.store(false);
    memcpy(nativeCompleted.data(), b, nativeCompleted.size());
}
struct Object {
    alignas(16) std::array<unsigned char, 0x238> data{};
    Object(uint32_t discovery = 2, uint32_t architecture = kAUv2, uint32_t type = kARAX) {
        *reinterpret_cast<uint32_t*>(data.data() + 0x1ec) = architecture;
        *reinterpret_cast<uint32_t*>(data.data() + 0x1e0) = type;
        *reinterpret_cast<uint32_t*>(data.data() + 0x1f0) = discovery;
        *reinterpret_cast<void**>(data.data() + 0x1a8) = discovery == 2 ? &factoryToken : nullptr;
    }
    void* callback() const { return *reinterpret_cast<void* const*>(data.data() + 0x58); }
    bool nativeBytesPreserved() const { return data == nativeCompleted; }
};
void reset(Case c) {
    nextCase = c; setupCalls = createCalls = factoryCalls = 0;
    nativeARASetupEnabled.store(true); active.store(true);
    originalSetup = fakeSetup; originalReadSamples = fakeRead;
    createNativeAU = fakeCreate; getNativeFactory = fakeFactory;
}
void runFailure(Case c, const char* reason) {
    reset(c);
    Object o;
    setupNativeARA(o.data.data());
    check(setupCalls == 1, "failure calls original setup exactly once");
    check(o.nativeBytesPreserved(), "failure preserves ALL native-completed object bytes");
    check(!nativeARASetupEnabled.load(), "failure disables future manual discovery");
    check(active.load(), "failure retains preference/process isolation");
    check(createCalls == 0 && factoryCalls == 0, "supported object never recreates native AU/factory");
    const long end = ftell(logFile);
    rewind(logFile); char log[16384]{};
    const auto bytes = fread(log, 1, sizeof(log) - 1, logFile); log[bytes] = 0;
    check(strstr(log, reason), "failure records exact diagnostic");
    check(strstr(log, "compatibility_valid=0"), "failure never reports compatibility pass");
    fseek(logFile, end, SEEK_SET);
    nextCase = Case::NoDocument;
    Object next(0);
    setupNativeARA(next.data.data());
    check(setupCalls == 2 && next.nativeBytesPreserved(), "next setup passes through native behavior");
    check(createCalls == 0 && factoryCalls == 0, "disabled bridge never performs new factory discovery");
}
}
int main() { @autoreleasepool {
    logFile = tmpfile();
    check(logFile != nullptr, "owned diagnostic stream");
    reset(Case::Valid); Object valid;
    setupNativeARA(valid.data.data());
    check(setupCalls == 1, "valid original setup exactly once");
    check(valid.callback() == reinterpret_cast<void*>(readNativeSourceSamples), "valid original callback atomically wrapped");
    auto expected = nativeCompleted;
    *reinterpret_cast<void**>(expected.data() + 0x58) = reinterpret_cast<void*>(readNativeSourceSamples);
    check(valid.data == expected, "valid wrapper changes ONLY expected callback slot");
    check(nativeARASetupEnabled.load(), "valid setup retains enhancement");
    reset(Case::AlreadyWrapped); Object alreadyWrapped;
    setupNativeARA(alreadyWrapped.data.data());
    check(setupCalls == 1 && alreadyWrapped.nativeBytesPreserved(), "already wrapped native callback remains unchanged");
    check(nativeARASetupEnabled.load(), "already wrapped callback is compatible");
    runFailure(Case::BadSize, "source_reader_interface_layout_mismatch");
    runFailure(Case::BadInterface, "source_reader_interface_layout_mismatch");
    runFailure(Case::BadCallback, "source_reader_callback_mismatch");
    runFailure(Case::DisabledDuringSetup, "setup_disabled_during_native_setup");
    reset(Case::NoDocument); Object noDocument;
    setupNativeARA(noDocument.data.data());
    check(noDocument.nativeBytesPreserved() && nativeARASetupEnabled.load(), "no-document native result unchanged");
    reset(Case::NoDocument); Object unavailable(0);
    setupNativeARA(unavailable.data.data());
    check(setupCalls == 1 && createCalls == 1 && factoryCalls == 0, "missing temporary unit uses one native discovery attempt");
    check(*reinterpret_cast<uint32_t*>(unavailable.data.data() + 0x1f0) == 1 &&
        *reinterpret_cast<void**>(unavailable.data.data() + 0x1a8) == nullptr,
        "missing factory retains native unsupported discovery state");
    check(unavailable.nativeBytesPreserved() && nativeARASetupEnabled.load(), "unsupported discovery is not a runtime compatibility pass or fatal failure");
    reset(Case::Valid); Object ordinary(2, kAUv2, fourCC('a','u','f','x'));
    setupNativeARA(ordinary.data.data());
    check(ordinary.nativeBytesPreserved() && nativeARASetupEnabled.load(), "ordinary AU setup unchanged");
    reset(Case::Valid); Object otherArchitecture(2, fourCC('a','u','v','3'));
    setupNativeARA(otherArchitecture.data.data());
    check(otherArchitecture.nativeBytesPreserved(), "AUv3 setup unchanged");
    reset(Case::Valid); active.store(false); Object inactive;
    setupNativeARA(inactive.data.data());
    check(inactive.nativeBytesPreserved(), "inactive bridge setup unchanged");
    fclose(logFile); logFile = nullptr;
    printf("{\"checks\":%u,\"pass\":true,\"scope\":\"offline actual setup wrapper with fake native callback; no Logic/plugin launch\"}\n", checks);
} }
