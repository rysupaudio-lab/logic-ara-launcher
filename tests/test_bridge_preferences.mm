// Foundation-only cached-object isolation controls; no Logic/AppKit UI/plugin
// activation. All persistent domains are unique synthetic test domains.
#define LOGIC_ARA_BRIDGE_TEST 1
#include "../native/Bridge.mm"
namespace { extern "C" bool originalForceInProcess(void*) { return false; } }

namespace {
unsigned checks = 0;
void check(bool okay, const char* what) {
    ++checks;
    if (!okay) { fprintf(stderr, "FAIL: %s\n", what); std::abort(); }
}
bool equal(id a, id b) { return a == b || [a isEqual:b]; }
}

int main() { @autoreleasepool {
    NSString* unique = NSUUID.UUID.UUIDString;
    NSString* originalName = [@"org.rysupaudio.logic-ara-test.original." stringByAppendingString:unique];
    NSString* privateName = [@"org.rysupaudio.logic-ara-launcher.test." stringByAppendingString:unique];
    NSString* vendorName = [@"org.rysupaudio.logic-ara-test.vendor." stringByAppendingString:unique];
    testLogicPreferencesDomain = (__bridge CFStringRef)originalName;
    preferenceDomain = (__bridge CFStringRef)privateName;
    // Capture a real standard singleton before installing the accessor override,
    // exactly as an AppKit caller can do before the bridge constructor.
    capturedStandardDefaults = [NSUserDefaults standardUserDefaults];
    NSUserDefaults* cached = capturedStandardDefaults;
    isolatedDefaults = [[NSUserDefaults alloc] initWithSuiteName:privateName];
    installPrivatePreferenceArguments();
    NSUserDefaults* originalSuite = [[NSUserDefaults alloc] initWithSuiteName:originalName];
    NSUserDefaults* vendor = [[NSUserDefaults alloc] initWithSuiteName:vendorName];
    [originalSuite setPersistentDomain:@{@"identity": @"original", @"untouched": @17} forName:originalName];
    [vendor setPersistentDomain:@{@"identity": @"vendor", @"untouched": @23} forName:vendorName];
    [isolatedDefaults setPersistentDomain:@{@"identity": @"private"} forName:privateName];
    [originalSuite synchronize]; [vendor synchronize]; [isolatedDefaults synchronize];
    CFDictionaryRef originalBefore = CFPreferencesCopyMultiple(nullptr, (__bridge CFStringRef)originalName,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    active.store(true);
    logFile = tmpfile();
    installCorePreferencesIsolation();
    check(!corePreferencesMethodMatches(nullptr, "v16@0:8"), "missing private method refuses ABI admission");
    Method identifierMethod = class_getInstanceMethod([NSUserDefaults class], sel_registerName("_identifier"));
    check(!corePreferencesMethodMatches(identifierMethod, "v16@0:8"), "incorrect private signature refuses ABI admission");
    check(corePreferencesMethodMatches(identifierMethod, "^{__CFString=}16@0:8"), "actual identifier signature/image verified");
    installDefaultsInstanceIsolation();
    Method accessor = class_getClassMethod([NSUserDefaults class], @selector(standardUserDefaults));
    IMP originalAccessor = method_setImplementation(accessor, reinterpret_cast<IMP>(standardDefaults));
    check([NSUserDefaults standardUserDefaults] == isolatedDefaults, "new accessor uses private object");
    check(NSApp == nil, "native panel-config probe starts without an application");
    check(equal([isolatedDefaults objectForKey:@"NSUseRemoteSavePanel"], @NO), "actual private argument helper disables remote panels");
    check(equal([cached volatileDomainForName:NSArgumentDomain][@"NSUseRemoteSavePanel"], @NO), "cached argument-domain access retains local-panel choice");
    check(nativeRemotePanelConfig() != nullptr, "native factory code/hash identifies the real config getter");
    check(verifyNativeLocalPanelConfig(), "actual native AppKit config getter returns local route");
    check(NSApp == nil, "native config getter creates no application or panel");
    check(cached != isolatedDefaults && cached == capturedStandardDefaults, "cached identity retained");
    [cached setObject:@"path-from-own-open-panel" forKey:@"NSOSPLastRootDirectory"];
    check(equal([isolatedDefaults objectForKey:@"NSOSPLastRootDirectory"], @"path-from-own-open-panel"), "cached panel write reaches private suite");
    check(equal([cached stringForKey:@"identity"], @"private"), "cached reads use private domain");
    check(equal([vendor stringForKey:@"identity"], @"vendor"), "explicit third-party suite keeps own reads");
    [originalSuite setObject:@"separate-logic-receiver" forKey:@"NSWindow Frame GoToSheet"];
    check(equal([isolatedDefaults objectForKey:@"NSWindow Frame GoToSheet"], @"separate-logic-receiver"), "separate protected-domain instance redirects");
    check(defaultsReceiver(originalSuite) == isolatedDefaults, "actual domain getter identifies independent protected instance");
    // Deliberately bypass the NSUserDefaults method hook to exercise the actual
    // Foundation -> private container-aware CoreFoundation setter boundary.
    using OriginalSet = void (*)(id, SEL, id, NSString*);
    reinterpret_cast<OriginalSet>(originalDefaultsOperation(@selector(setObject:forKey:)))(
        originalSuite, @selector(setObject:forKey:), @"private-cf-setter", @"container-boundary");
    check(equal([isolatedDefaults objectForKey:@"container-boundary"], @"private-cf-setter"), "container-aware setter redirects original-IMP bypass");
    CFPreferencesSetAppValue(CFSTR("direct-cf"), CFSTR("private-cf-value"), (__bridge CFStringRef)originalName);
    check(equal([isolatedDefaults objectForKey:@"direct-cf"], @"private-cf-value"), "direct public CF app setter reaches protected internal boundary");
    CFPropertyListRef appValue = CFPreferencesCopyAppValue(CFSTR("direct-cf"), (__bridge CFStringRef)originalName);
    check(appValue && CFEqual(appValue, CFSTR("private-cf-value")), "private CF app getter redirects protected identifier");
    if (appValue) CFRelease(appValue);
    CFPropertyListRef tupleValue = CFPreferencesCopyValue(CFSTR("direct-cf"), (__bridge CFStringRef)originalName,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    check(tupleValue && CFEqual(tupleValue, CFSTR("private-cf-value")), "private CF tuple getter preserves user/host and redirects identifier");
    if (tupleValue) CFRelease(tupleValue);
    using NamedSet = void (*)(id, SEL, id, NSString*, NSString*);
    reinterpret_cast<NamedSet>(objc_msgSend)(vendor, sel_registerName("setObject:forKey:inDomain:"),
        @"private-named-write", @"private-named", originalName);
    check(equal([isolatedDefaults objectForKey:@"private-named"], @"private-named-write"), "private explicit-domain setter redirects");
    [vendor setObject:@"vendor-write" forKey:@"local"];
    check(equal([vendor objectForKey:@"local"], @"vendor-write") && [isolatedDefaults objectForKey:@"local"] == nil, "third-party write remains separate");
    [cached setInteger:47 forKey:@"integer"]; check([cached integerForKey:@"integer"] == 47, "integer ABI");
    [cached setFloat:1.25f forKey:@"float"]; check([cached floatForKey:@"float"] == 1.25f, "float ABI");
    [cached setDouble:2.5 forKey:@"double"]; check([cached doubleForKey:@"double"] == 2.5, "double ABI");
    [cached setBool:YES forKey:@"bool"]; check([cached boolForKey:@"bool"], "BOOL ABI");
    [cached setURL:[NSURL fileURLWithPath:@"/private/own-test-path"] forKey:@"url"];
    check(equal([cached URLForKey:@"url"].path, @"/private/own-test-path"), "URL ABI");
    [cached setObject:@[@"a",@"b"] forKey:@"array"];
    check(equal([cached arrayForKey:@"array"], @[@"a",@"b"]), "array getter");
    check(equal([cached stringArrayForKey:@"array"], @[@"a",@"b"]), "string array getter");
    [cached setObject:@{@"a":@1} forKey:@"dictionary"];
    check(equal([cached dictionaryForKey:@"dictionary"], @{@"a":@1}), "dictionary getter");
    NSData* bytes = [@"data" dataUsingEncoding:NSUTF8StringEncoding];
    [cached setObject:bytes forKey:@"data"]; check(equal([cached dataForKey:@"data"], bytes), "data getter");
    [cached setValue:@"kvc" forKey:@"kvc"]; check(equal([cached valueForKey:@"kvc"], @"kvc"), "KVC get/set");
    check(equal([cached dictionaryRepresentation][@"integer"], @47), "representation uses private object");
    [cached removeObjectForKey:@"integer"]; check([isolatedDefaults objectForKey:@"integer"] == nil, "cached remove affects private suite");
    [cached registerDefaults:@{@"registered":@91}]; check([cached integerForKey:@"registered"] == 91, "register default dispatch");
    check([cached synchronize], "cached synchronize dispatch");
    // Exact protected-name APIs map to the private domain. The protected name
    // is synthetic in this test binary; even a broken guard cannot touch Logic.
    [cached setPersistentDomain:@{@"named":@"private-replacement"} forName:originalName];
    check(equal([isolatedDefaults persistentDomainForName:privateName], @{@"named":@"private-replacement"}), "named persistent write remaps protected domain");
    check(equal([vendor persistentDomainForName:originalName], @{@"named":@"private-replacement"}), "explicit protected read remaps on other receivers");
    [vendor setPersistentDomain:@{@"vendor":@"still-vendor"} forName:vendorName];
    check(equal([vendor persistentDomainForName:vendorName], @{@"vendor":@"still-vendor"}), "other explicit domain unchanged");
    [cached setVolatileDomain:@{@"volatile":@1} forName:originalName];
    check(equal([cached volatileDomainForName:originalName], @{@"volatile":@1}), "volatile protected name remaps");
    check([[cached volatileDomainNames] containsObject:privateName], "volatile names use private object");
    [cached removeVolatileDomainForName:originalName];
    check([cached volatileDomainForName:originalName].count == 0, "volatile remove remaps");
    [cached removePersistentDomainForName:originalName];
    check([isolatedDefaults persistentDomainForName:privateName].count == 0, "protected domain removal is private");
    [vendor synchronize]; [cached synchronize];
    active.store(false); // independent read of the real synthetic source domain
    CFDictionaryRef originalAfter = CFPreferencesCopyMultiple(nullptr, (__bridge CFStringRef)originalName,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    active.store(true);
    check(originalBefore && originalAfter && CFEqual(originalBefore, originalAfter), "original protected persistent contents unchanged");
    check(defaultsDomainName(NSGlobalDomain) == NSGlobalDomain, "global domain not redirected");
    check(equal(defaultsDomainName(vendorName), vendorName), "vendor domain name not redirected");
    check([cached objectIsForcedForKey:@"nonexistent"] == [isolatedDefaults objectIsForcedForKey:@"nonexistent"], "forced-key BOOL getter");
    check([cached objectIsForcedForKey:@"nonexistent" inDomain:originalName] == [isolatedDefaults objectIsForcedForKey:@"nonexistent" inDomain:privateName], "forced-domain BOOL getter");
    [cached addSuiteNamed:originalName]; [cached removeSuiteNamed:originalName];
    check(defaultsReceiver(vendor) == vendor && defaultsReceiver(cached) == isolatedDefaults, "receiver identity boundary");
    check(navigationPreferenceTraces.load() > 0, "two-key navigation trace observed without logging values");
    // Restore only this test process's method dispatch before removing its own
    // named domains. Never restore/delete any user's domain or preference file.
    method_setImplementation(accessor, originalAccessor);
    active.store(false);
    for (const auto& operation : defaultsOperations)
        method_setImplementation(class_getInstanceMethod([NSUserDefaults class], operation.selector), operation.original);
    for (const auto& operation : corePreferencesOperations)
        method_setImplementation(operation.method, operation.original);
    [originalSuite removePersistentDomainForName:originalName];
    [isolatedDefaults removePersistentDomainForName:privateName];
    [vendor removePersistentDomainForName:vendorName];
    [originalSuite synchronize]; [isolatedDefaults synchronize]; [vendor synchronize];
    if (originalBefore) CFRelease(originalBefore); if (originalAfter) CFRelease(originalAfter);
    fclose(logFile); logFile = nullptr;
    printf("{\"checks\":%u,\"pass\":true,\"scope\":\"Foundation cached-standard operations and unique synthetic domains only; no Logic/plugin/UI launch\"}\n",checks);
} }
