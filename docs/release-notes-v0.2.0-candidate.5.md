# Logic ARA Launcher 0.2.0-candidate.5

This experimental prerelease provides an installable native Apple Silicon app
for **Logic Pro 12.4 (6707)**. It verifies your licensed original Apple-signed
Logic, starts an unchanged private copy with the ARA bridge, and removes that
copy after normal Quit. Your installed Logic is read and verified, never patched
or re-signed.

The app and DMG are Developer ID signed and notarized. Stapled tickets validate,
and Gatekeeper accepts both as Notarized Developer ID. The ZIP contains the
stapled app. No Python or compiler is needed at runtime. No Apple application,
ARA SDK, source audio, third-party plug-in, private test helper or license is
included.

## Requirements and installation

- Apple Silicon; exact original Logic Pro **12.4, build 6707**. Other host builds
  refuse admission.
- Minimum executable target macOS 15.4. Normal Logic workflows were tested on
  **macOS 27.0 (26A428)**; this does not qualify every macOS release.
- Your existing Logic and third-party plug-in licenses, plus backed-up projects.

Open the DMG and drag **Logic ARA Launcher.app** to Applications, or extract the
ZIP. Open the launcher, check compatibility, then open a backed-up .logicx copy.
Use the visible private Logic normally and select the plug-in's genuine ARA AU
variant. Keep the launcher open; save your project and quit its Logic copy
normally when finished. Diagnostics are retained for review.

## Verified native workflow

Normal launcher UI opened synthetic mono/stereo projects, displayed genuine ARA
editors, saved native projects and exported 48 kHz/24-bit WAVs through Logic's
normal offline Bounce dialogs. Ordinary stock AU insertion/recall also passed.

With **autochoir 1.0.0**, the fixture has three mono sources, one stereo source and
eight full, trimmed or reused regions. Real control edits changed native audio.
The saved matching Detune 0.0500 / Formant +5 state recalled in both editors and
produced **sample-identical warm and two independent cold renders**: 408000 stereo
frames, zero changed samples, maximum/RMS difference zero. The second cold used
the exact final notarized ZIP; the earlier cold used the same native code and
bridge with the previous bundled guide/signature.

Native source-read callbacks, saved AU state, media graph and ARA sidecars were
observed. Returned third-party source PCM fingerprints were not measured, and no
ARA certification or universal compatibility is claimed.

## Known limits

- **Different Formant settings on autochoir's shared-document inserts are not
  qualified.** Warm and cold audio differed despite correctly recalled controls.
  Waiting for visible processing to finish did not remove that failure. Both
  Formants at -5 matched the cold result; both at +5 matched the warm result. The
  failed mixed-setting criterion remains recorded; host/vendor attribution is
  not established by an official supported-host comparison.
- **Melodyne 5.4.2** required activation for editing. **VoiceAssist 1.3.24** reported
  an expired trial in its bound editor. Neither was activated or given a new trial.
- **Sync Vx** opened its genuine mono ARA editor/setup wizard and saved the insert
  without a visible activation/trial challenge. Its participating source tracks,
  DSP licensing, alignment/editing and cold audio are **not qualified**.
- Earlier RysUpPitch development-candidate tests are separate. This launcher does
  not include or install a RysUpPitch compatibility-fix binary.
- Other ARA plug-ins, host builds, OS builds, edit types and arbitrary customer
  sessions remain outside the tested scope.

## Preservation and shared settings

Tests verified original Logic signature/code pins and recorded installed
third-party code/metadata unchanged. Owned Logic and launcher processes exited
normally; private app copies and their session locks were removed. No force quit,
signals, Don't Save or hardware playback was used.

DAW/audio preference access uses the private launcher suite. The macOS file-panel
service shares two navigation-history values with regular Logic:
`NSOSPLastRootDirectory` and `NSWindow Frame GoToSheet`. **This is not full system
or filesystem isolation.** The consumer app does not restore normal navigation
history. Qualification tests restored only their exact known test preimages
after owned Logic exited and verified the entire **2021-key** normal preference
baseline, including fresh CF daemon and disk checks in the final run. Global
preferences, audio devices, plug-in preferences and user files remain shared
resources.

See the included sanitized qualification JSON and repository qualification notes
for exact numerical scope and artifact hashes. This independent experiment is
not endorsed by Apple or ARA plug-in vendors.
