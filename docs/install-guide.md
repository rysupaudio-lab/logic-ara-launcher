# Logic ARA Launcher — experimental candidate

This native Apple Silicon application starts an unchanged private copy of your
own licensed Logic Pro 12.4 (6707). It verifies the original Apple signature and
exact executable/framework hashes. It does not patch or re-sign Logic, install
plug-ins, alter plug-in licensing, or select a default application for projects.
No Apple application, ARA SDK, third-party plug-in or license is included.

The executable requires macOS 15.4 or later. Normal-app tests use macOS 27.0
(26A428); the minimum deployment target does not establish support for every
macOS version. An unreviewed host build or incompatible native runtime refuses
startup. See the exact current qualification at:
https://github.com/rysupaudio-lab/logic-ara-launcher/blob/main/docs/normal-app-candidate.md

## Install and use

1. Open the DMG and drag Logic ARA Launcher.app to Applications, or extract the ZIP
   and move the application there. No Python or compiler is needed.
2. Open the launcher and choose Check compatibility. Select your original licensed
   Logic installation if it is outside Applications.
3. Choose Open a backed-up project and select a separate writable .logicx copy.
   Keep the launcher running while working in its visible private Logic copy.
4. Insert the plug-in's actual ARA Audio Unit variant through Logic. Normal vendor
   licensing still applies. Let the plug-in finish its source processing before
   editing or bouncing. Save and bounce through Logic normally.
5. Save your project and quit that Logic copy normally. The launcher verifies the
   original installation and removes the temporary application copy.

The project you open is writable; the launcher does not create a project backup
for you. It never hides, takes over or quits another Logic process. If the launcher
exits first, a live private Logic copy and its lock are preserved. Quit that copy
normally, reopen the launcher and choose Clean finished session. Cleanup checks
every process using that exact private copy before removing it.

## Known limits

This is an unsupported experiment with exact-build admission and bounded tests,
not a promise of universal ARA or arbitrary customer-session compatibility.
Autochoir 1.0.0 showed conflicting Formant behavior between warm and cold renders
when its shared-document inserts used different settings. That workflow is not
qualified. Matching settings have separate measured controls; read the current
qualification before choosing a workflow. The launcher does not repair vendor
processing behavior or the released RysUpPitch 1.1.8 editor/archive issues.

DAW and audio preference access uses the private launcher suite. The normal macOS
file-panel service shares the last folder (NSOSPLastRootDirectory) and Go To Folder
window placement (NSWindow Frame GoToSheet) with regular Logic. The consumer
launcher does not restore these normal navigation-history values after a session.
Preference redirection is not an OS sandbox: global settings, audio devices,
plug-in preferences, sound libraries and other user files remain accessible.

If a compatibility warning appears during work, save your project, remove the
affected insert and restart before further ARA editing. A runtime warning leaves
the native document open; it does not forcibly terminate Logic.

## Storage and removal

Working copies and diagnostics default to ~/Library/Caches/LogicARALauncher/.
Advanced users can select a mounted working disk with the absolute
LOGIC_ARA_CACHE_ROOT environment variable, or CLI --cache /absolute/folder.
A different filesystem receives a full signature-preserving Logic copy, so it
needs enough free space. Keep the working disk mounted until Logic has quit and
cleanup has completed.

To uninstall, quit the launcher's Logic copy and launcher, then move only Logic
ARA Launcher.app to Trash. Your installed Logic and saved projects are unchanged.
Remove retained diagnostics only after every launcher session has ended.

Logic Pro is an Apple trademark. This project is independent of Apple and ARA
plug-in vendors.
