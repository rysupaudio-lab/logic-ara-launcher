# Logic ARA Launcher

Experimental native Apple Silicon ARA 2 launcher for **Logic Pro 12.4, build 6707**.
It starts a signature-preserving private copy of your own Logic installation with
a process-local bridge. The installed application is read and verified, never
patched or re-signed. Unknown builds are refused.

**Experimental alpha.** Admission is limited to one exact Logic build. Native
mono and stereo ARA source acquisition, independent region edits and native
saving have been tested with a development build of RysUpPitch. The stereo test
covers six tracks and twelve regions: independent left/right melodies,
proportional channels, anti-phase, left-only, right-only and quadrature audio.
Two independent cold processes restored all 48 saved note identities/offsets
and produced sample-identical mixes and all six stems. These are bounded
synthetic-audio checks; other plug-ins and general customer sessions remain
unqualified.

The RysUpPitch tests use unreleased compatibility fixes. The installed/released
RysUpPitch 1.1.8 has separate editor and archive compatibility issues; this launcher
alone does not fix them. Other ARA plug-ins, including licensed Melodyne editing,
have not been qualified.

## Install the candidate

The native 0.2.0 candidate is being qualified locally. It is **not yet a public
binary release**. Published alpha.2 remains a source-only release.

The installable candidate requires an Apple Silicon Mac, macOS 15.4 or later,
and your own licensed original Apple-signed Logic Pro **12.4 (6707)**. It contains
a native application and our bridge, with no Python or compiler requirement at
runtime. No Logic binaries, ARA SDK, or third-party plug-ins are distributed.

Open the DMG, drag **Logic ARA Launcher.app** to Applications, and open it.
Choose **Check compatibility**, **Launch Logic**, or **Open a backed-up project**.
The selected Logic installation is verified before a private copy is prepared.
The visible private Logic application is used normally. Insert an ARA-capable
AU in its ARA variant; normal third-party licensing still applies.

Keep the launcher open while working. Quit its Logic copy normally when finished;
the launcher verifies the original installation and removes the private copy.
If you quit the launcher first or it stops unexpectedly, any live Logic copy and
its lock are preserved. After that copy has exited, reopen the launcher and choose
**Clean finished session**. Cleanup refuses any recorded PID that is still alive.
Diagnostics stay under `~/Library/Caches/LogicARALauncher/runs/`.
Advanced use can place working copies on another disk by setting the absolute
`LOGIC_ARA_CACHE_ROOT` environment variable before launching, or using CLI
`--cache /absolute/folder`. A different filesystem receives a full,
signature-preserving copy. The working folder must stay outside the installed
Logic bundle. Cleanup refuses every live process using the exact private copy,
including a second process started by Launch Services.

To uninstall, quit the launcher's private Logic copy and the launcher, then move
only **Logic ARA Launcher.app** to Trash. Removing the launcher does not modify
your installed Logic or your projects. Session diagnostics can be removed from
the cache after all launcher sessions have ended.

Native CLI use, after installing:

```sh
"/Applications/Logic ARA Launcher.app/Contents/MacOS/Logic ARA Launcher" --check
"/Applications/Logic ARA Launcher.app/Contents/MacOS/Logic ARA Launcher" "/absolute/path/Backed Up Project.logicx"
```

## Build from source

Developers need Python 3.9+ and Apple's Command Line Tools. Building and signing
are separate from end-user installation.

```sh
./build.sh
"dist/Logic ARA Launcher.app/Contents/MacOS/Logic ARA Launcher" --check
open "dist/Logic ARA Launcher.app"
```

Create a local zip/DMG candidate with an ad-hoc signature:

```sh
/usr/bin/python3 tools/package_app.py
```

For a Developer ID candidate, pass the available signing identity with
`--identity`. Packaging does not submit for notarization or publish anything.
The source `launcher.py` remains available for the separate qualification harness;
it is not the native app entry point and is not included in the binary app.

The private host uses a separate preferences domain. It never hides Logic or
changes any application's Dock visibility. The launcher never selects
a `.logicx` default application and unregisters its own copy from Launch Services.
Open projects through the launcher when you need the bridge. Save changes in your
test copy of the project: the opened project itself is writable.
On the private copy's first run, finish Logic's own welcome or What's New panels
so it can open the selected project.

In Logic, insert an ARA-capable AU in its ARA variant on an audio track. Depending on
the plug-in/host workflow, brief playback may be needed before source audio becomes
available. ARA access does not remove a plug-in's licensing requirements.

## Scope and limitations

- One exact engine SHA-256 and native ARM64 ABI are admitted. A different Logic
  release requires new analysis and qualification, not an edited version string.
- This is an unsupported experiment. Keep project backups and use test projects.
- Runtime discovery is generic; plug-in editor, archive and rendering compatibility
  remain plug-in responsibilities. Melodyne editing has not been qualified.
- The helper changes dispatch data in its own process; signed files are unchanged.
  macOS must permit the original application to load the helper. There is no
  entitlement alteration, signature-check bypass, or instruction patch fallback.
- Separate preferences are not an OS sandbox. Logic can access normal user data,
  audio devices, sound libraries and plug-ins. Existing Logic processes are not
  attached to or terminated. Stopping the launcher preserves a still-running
  private Logic copy and its lock; quit that copy yourself when finished.
- A built app can be signed and packaged without Python in its runtime. Public
  distribution and notarization remain pending the new normal-app qualification.

## Development

```sh
/usr/bin/python3 -m unittest discover -s tests -v
```

See [the runtime design](docs/design.md) and [qualification status](docs/qualification.md).
Only this launcher's source belongs in the public repository. Keep local projects,
audio, private plug-in source, helper traces and Apple binaries outside it.

Logic Pro is an Apple trademark. This project is independent and is not endorsed
by Apple or ARA plug-in vendors.
