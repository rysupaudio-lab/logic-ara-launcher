# Runtime design

The launcher verifies the installed bundle identity, Apple signature, version,
build, and full MAAudioEngine hash. It creates an APFS clone in a unique owned run
directory and verifies the copy before executing its Mach-O entry point directly.
It does not use `open` to dispatch the project to an arbitrary existing process.
For an explicitly selected project, the helper sends an Open Documents Apple Event
addressed to its own process on the main queue, two seconds after Logic's finish-
launch notification. Same-process Apple Events can execute their handler on the
sending thread; Logic's application setup requires the main queue. An already-
open copy of that exact project is left in place.

The injected helper checks its executable path against that owned copy and checks
the resolved engine symbol's image path. The current ABI has an exported
`ARA_Interface` vtable with `SetupSubClass` at slot 14. For AUv2 ARA interfaces,
the wrapper obtains a genuine factory using Logic's own AU creation and factory
validation functions, fills the missing discovery state, then invokes Logic's
original setup. AUv3 behavior is preserved. No archive IDs are substituted and
no editor view is redirected to an unrelated processor.

This host's shared ARA interface can precreate audio regions with the first
track's stream. Later parent-track changes leave that reader stream unchanged.
With a mono first track, the native decoder consequently averages stereo L/R
into its left buffer while retaining the original right buffer. A stereo parent
track and a two-channel AU do not correct this source-reader association.

The bridge wraps the native ARA source-read callback and the concrete stream's
mode getter through process-local dispatch data. An exact, verified two-channel
source read establishes a thread-local scope for its selected reader stream.
Only inside that scope, a mono mode query returns standard stereo. Logic's own
reader and decoder still supply every sample. Stored track modes, region links,
mono sources and ordinary playback remain unchanged. Nested reads restore their
previous scope, including during exception unwinding. The helper verifies both
framework hashes, original callback/getter addresses and expected vtables before
installing these wrappers; a missing ARA document leaves its callback untouched.

No signed file or Apple instruction bytes are modified. A private writable copy of
the process's vtable page supplies the wrapper. Preference APIs are redirected to
the launcher's domain, normal saved-state reopening is disabled and the injection
environment variable is removed before host child-process creation.

The source-bound version guard is intentional. Object offsets and function ABI are
private implementation details. Missing symbols, unexpected vtable contents or a
different image path refuse bridge initialization. The bridge exits its validated
child before completing an invalid startup; the launcher itself never terminates
a live Logic process. Normal exit unregisters and deletes the generated copy.
Session JSON records source hashes, child PID, status and source verification.
The bridge additionally verifies its launcher's parent PID before activation.
There is no app-hiding behavior. A stopped launcher preserves a still-live child,
copy and lock: original ownership does not prove the process still holds only
test projects. The private qualification harness releases automation when it
sees a non-test document or cannot establish live document ownership.
