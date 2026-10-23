# Native bridge

`Bridge.mm` is source code for a runtime compatibility experiment. It contains
no Apple executable bytes and needs no ARA SDK. Build on Apple Silicon using
the repository's `build.sh`, or compile only the helper:

```sh
xcrun clang++ -arch arm64 -mmacosx-version-min=15.4 -std=c++17 -fobjc-arc -dynamiclib \
  -framework Foundation -framework AppKit -framework AudioToolbox -framework Carbon \
  -Wl,-undefined,dynamic_lookup native/Bridge.mm -o native/LogicARABridge.dylib
codesign --force --sign - native/LogicARABridge.dylib
```

The helper is loaded into the launcher's verified private Logic copy. It never
writes or re-signs Logic, its frameworks, plug-ins, receipts, or their code.
It does not alter licensing or signature validation. It makes one copy-on-write
change to an ARA vtable data slot in its own process and restores the memory
page's previous permissions afterward.

## Launcher contract

- `LOGIC_ARA_APP_PATH`: absolute path to the private copied `.app`.
- `LOGIC_ARA_PARENT_PID`: PID of the Python launcher; must match the actual parent
  before the helper activates.
- `LOGIC_ARA_LOG_PATH`: absolute path to an append-only session log owned by the
  current user. A symlink at the log path is rejected.
- `LOGIC_ARA_PREFERENCES_DOMAIN`: `org.rysupaudio.logic-ara-launcher` or a child
  domain beginning with that value and a dot.
- `LOGIC_ARA_PROJECT_PATH`: optional explicit absolute path to an existing local
  `.logicx` project. After application launch, the helper checks the open document
  URLs and, if necessary, sends one Open Documents (`aevt`/`odoc`) Apple Event
  addressed only to its own PID. The send runs on the main queue, two seconds
  after `NSApplicationDidFinishLaunchingNotification`. It never uses LaunchServices or the document
  controller's open method, and does not dismiss startup or project dialogs.
- `DYLD_INSERT_LIBRARIES`: supplied by the launcher to load this helper. The
  constructor immediately removes it from the process environment so child
  processes do not inherit injection.

Successful initialization writes `bridge_ready`; an identified owned-process
validation failure writes `bridge_refused` and exits with status 78. Missing
environment or a different executable leaves the helper inactive. The launcher
must also treat a missing ready marker as failure. Failure to open the log cannot
produce a marker and exits 78 for the selected process.

For an explicit project, `odoc_requested` and `odoc_status` record event delivery;
`odoc_skipped` means that exact project was already listed as open. A zero delivery
status is not proof that Logic finished loading its live song. A first-run dialog
may still require the user to continue normally before the project can open.
An empty project environment value is treated as no project request. The helper
does not use `NSApp.running` as a substitute for the finish notification and does
not retry a timed-out send, because the original event may still be delivered.

### Project-open thread requirement

An earlier experiment sent the self-addressed event from a background queue.
Crash report `Logic Pro-2026-10-23-171257.ips` (PID 2709) showed SIGTRAP on
`com.apple.root.user-initiated-qos`: `AESendMessage` synchronously entered AppKit's
open-documents handler and finish-launch notification, then
`setupAppFactorySharedInstance` failed Swift executor isolation with
`_dispatch_assert_queue_fail`. This disproved the assumption that a self-addressed
Apple Event would always be handled on the main queue. The corrected helper
sends only on the main queue after the actual finish notification, matching the
previously exercised own-process open path. It does not bypass any assertion.

The bridge requires version `12.4`, build `6707`, the original bundle identifier,
the exact native process path, exact loaded framework paths, and these complete
universal-file hashes:

| Framework path inside the copy | SHA-256 |
| --- | --- |
| `Contents/Frameworks/MAAudioEngine.framework/Versions/A/MAAudioEngine` | `f1ec685f407cd8a9ec73d3e94cdf3f7929bdcaa2168f221913c950bae76fec24` |
| `Contents/Frameworks/MACore.framework/Versions/A/MACore` | `331ce81830f253f3d47f9a219264a51c92bd1d66f03cafd166f04a8b5d6a745b` |

Do not update these hashes alone to admit another build: every private ABI
assumption below requires requalification. The Python launcher additionally
verifies the copied application's original Apple signature.

## Private ABI assumptions

The engine's exported `ARA_Interface` vtable starts with two ABI header entries.
Index 14 is `SetupSubClass`, verified against the corresponding exported symbol
before replacement. Newly inserted ARA interface objects invoke that virtual
method before their first support check.

For an AUv2 `aram` or `arax` interface with discovery state zero, the wrapper uses
the engine's existing `CreateV2AudioUnitForARAInterface` and
`Priv_GetARAFactoryFromV2AudioUnit` methods. The latter validates the plug-in's
native `AraF` handshake. The wrapper stores the actual returned opaque factory
and discovery result, calls the original `SetupSubClass`, and disposes its
temporary Audio Unit. AUv3 and other types go directly to original behavior.

The exact object fields used are:

| Offset | Meaning |
| --- | --- |
| `0x30` | Document-controller instance, read only for readiness logging |
| `0x1a8` | Validated ARA factory pointer |
| `0x1e0` | Synthetic component type (`aram` or `arax`) |
| `0x1e4` | Component subtype |
| `0x1e8` | Component manufacturer |
| `0x1ec` | Host architecture tag (`auv2`) |
| `0x1f0` | Discovery state: 0 unknown, 1 unsupported, 2 supported |

For hosting, the bridge interposes only `CMATagSet::IsForceInProcess`. It checks
the actual object against the exact `CMATagSet_plist` vtable, then reads that
subclass's component-key CFString at offset `0x20`. The engine formats this key
as `%08x-%08x-%08x` in type/subtype/manufacturer order. Only valid keys whose type
is `aram` or `arax` return true; all other objects use the original method.
`MAPrefs_ShowInProcessColumn` is supplied as true in the isolated Logic domain
to enable this existing per-component branch. No persistent tag is changed.
The bridge logs each distinct selected key once as `ara_inprocess` (at most 128
keys) for runtime qualification. The first ordinary `aufx`/`aumf` tag query logs
`normal_au_passthrough` with the original method's actual return value.
Because `dlsym` observes dyld interposition, resolving `IsForceInProcess` may
correctly return this helper's replacement. The guard accepts only that exact
replacement pointer or the qualified MACore image, and separately verifies the
helper's imported original call-through pointer belongs to qualified MACore.

## Isolation and limits

Logic's current-application and explicit `com.apple.logic10` CFPreferences
accesses are redirected to the launcher suite. `NSUserDefaults.standardUserDefaults`
returns that suite, with window restoration disabled through volatile defaults.
The selected process's running-application queries exclude other Logic processes
to prevent accidental handoff to the user's normal instance.

This is application preference isolation, not a security sandbox. Global macOS
preferences, plug-in preferences, audio devices, system component caches, and
other files or services used by Logic and plug-ins remain shared. The bridge
does not claim to intercept every possible direct file or preference API.

There are no product-specific selectors, component registration, editor routing,
factory wrappers, archive-ID substitutions, archive callbacks, or project-state
adapters. In particular, `document_present=1` proves only document creation;
it does not establish correct region access, editing, playback, or archive
restoration. Those require separate tests with each plug-in.
