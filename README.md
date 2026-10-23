# Logic ARA Launcher

Experimental native Apple Silicon ARA 2 launcher for **Logic Pro 12.4, build 6707**.
It starts a signature-preserving private copy of your own Logic installation with
a process-local bridge. The installed application is read and verified, never
patched or re-signed. Unknown builds are refused.

**Experimental alpha.** Admission is limited to one exact Logic build. Native
mono ARA source acquisition, independent edits and native saving have been tested
with a development build of RysUpPitch. Two independent cold processes restored
all saved edits and produced identical audio samples for three mono tracks and
seven regions. **Stereo is not qualified:** this Logic host path can deliver
`[mean(L,R), R]` through ARA despite a stereo source and stereo AU configuration.
Do not use this alpha for stereo ARA work.

The RysUpPitch tests use unreleased compatibility fixes. The installed/released
RysUpPitch 1.1.8 has separate editor and archive compatibility issues; this launcher
alone does not fix them. Other ARA plug-ins, including licensed Melodyne editing,
have not been qualified.

## Build and open

You need your own licensed Logic installation, an Apple Silicon Mac running Logic's
supported macOS version, Python 3.9+ and Apple's Command Line Tools (`xcode-select
--install`). No Logic binaries, ARA SDK, or third-party plug-ins are distributed.

```sh
./build.sh
./launcher.py --check
open "dist/Logic ARA Launcher.app"
```

The app offers launching Logic, opening a backed-up project, or checking
compatibility. CLI use:

```sh
./launcher.py "/absolute/path/Backed Up Project.logicx"
./launcher.py --logic "/Applications/Logic Pro.app" --check
```

Leave the launcher running until you quit its Logic copy. It removes that copy
afterward and keeps diagnostics under `~/Library/Caches/LogicARALauncher/runs/`.
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
- Build output is local and ad-hoc signed. It is not a notarized downloadable app.

## Development

```sh
/usr/bin/python3 -m unittest discover -s tests -v
```

See [the runtime design](docs/design.md) and [qualification status](docs/qualification.md).
Only this launcher's source belongs in the public repository. Keep local projects,
audio, private plug-in source, helper traces and Apple binaries outside it.

Logic Pro is an Apple trademark. This project is independent and is not endorsed
by Apple or ARA plug-in vendors.
