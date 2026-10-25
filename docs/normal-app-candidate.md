# Native installable candidate status

Version 0.2.0-candidate.5 is Developer ID signed and notarized, with validated
stapled tickets and accepted Gatekeeper assessments for the app and DMG. Its qualification covers
a bounded experimental profile. See
[release status and assets](https://github.com/rysupaudio-lab/logic-ara-launcher/releases)
for distribution availability. Historical alpha.2 remains source-only. No Apple application, third-party plug-in or license is distributed.

The native Apple Silicon app requires no Python or compiler at runtime. The
normal launcher UI opened a backed-up synthetic Logic project, displayed actual
ARA Audio Unit editors, saved the native project and exported 48 kHz/24-bit
offline WAVs through normal Logic dialogs. Six independent Logic processes
exited normally; each temporary application copy was removed, and the installed
Logic signature and pinned executable/framework bytes verified unchanged.
These runtime checks used Logic Pro 12.4 (6707) on macOS 27.0 (26A428).

## Current bounded third-party matrix

| Plug-in | Qualified observation | Retained limit |
| --- | --- | --- |
| autochoir 1.0.0 | Matching .0500 Detune / +5 Formant: edited warm and two cold native renders exact | Different Formants on shared-document inserts fail warm/cold equality |
| Sync Vx 17.1.42 | Two mono first-slot ARA inserts, REF/Sync vocal source rows, TimeWarp A / 100, native Save and two exact cold recalls | Pitch/general conformance unqualified; Time-off vs host-bypass region-edge residual retained |
| VoiceAssist 1.3.24 | Bound editor opened | Expired trial; functional DSP unqualified |
| Melodyne 5.4.2 | Installed genuine ARA component identified | Activation required for editing; functional DSP unqualified |

The additive [Sync Vx Time report](syncvx-time-qualification.md) and
[JSON](syncvx-time-qualification.json) qualify the exact unchanged published app.
The original qualification JSON and four original release assets are immutable
publication-time snapshots; their earlier Sync Vx pending status is historical.
This matrix is not an ARA certification or universal plug-in support claim.

## File dialogs and preference scope

DAW/audio preference access is redirected to the private suite. The normal macOS
file-panel service remains functional and shares two navigation-history values
with regular Logic: the last folder (`NSOSPLastRootDirectory`) and Go To Folder
window placement (`NSWindow Frame GoToSheet`). This is not complete filesystem
or system-service isolation. The consumer app does not overwrite normal
preferences after a session. The qualification workflow backs up these values
and restores only the exact known test preimages after all owned Logic processes
have exited, while checking that every other normal preference remains unchanged.

A rejected attempt to select local AppKit panels prevented Save even in a
standalone app without this bridge, on both internal and external test folders.
Normal remote panels were retained; no native validation, permissions or button
states were bypassed.

## Third-party evidence and limits

The autochoir 1.0.0 AU was inserted through Logic's actual ARA variant. The fixture
contained three mono sources, one stereo source and eight full, trimmed or reused
regions. Real editor control changes produced changed native audio, and native
Save preserved the actual AU state, media graph and ARA sidecars. Two independent
cold reopens recalled the exact displayed controls and produced sample-identical
408000-frame stereo renders at 48 kHz. A repeat render within a cold process was
also sample-identical. Native source-read callbacks were observed; exact returned
source PCM fingerprints were not measured for this third-party plug-in.

Different Formant values on two inserts are **not qualified**: that mixed setting
produced a warm/cold audio mismatch despite identical recalled AU parameter
state. Waiting for the visible render bar to disappear did not remove it. A
controlled run with both Formants at -5 exactly matched the cold renders; both
at +5 exactly matched the warm renders. This supports the observed shared
document processing behavior, but does not establish its behavior in an
officially supported vendor host. The failed mixed-setting criterion is retained;
no fitting or tolerance mask was used to turn it into a pass.

The saved matching +5 state was reopened in two independent cold processes from
byte-exact copies of the same immutable warm save. Both actual ARA editors
recalled the controls. Each 408000-frame native 48 kHz/24-bit stereo bounce was
sample-identical to the matching +5 warm reference and to the other cold render:
zero changed samples, maximum difference zero, RMS difference zero. The PCM32
SHA-256 is `3ab67fa56304cf4bb22ab824a7cc4cbe34f96a17dc90efea461f5efd0c9208bf`.

The first matching cold used the preceding bundled guide/resource signature;
the second used the exact final notarized ZIP. Native launcher bytes outside its
signature command/blob and the complete bridge are identical across those
artifacts. Normal Save/Quit, private-copy cleanup and the full 2021-key normal
preference baseline were verified after both runs. The final run also verified
fresh CF daemon and disk dictionaries after only the two known navigation
preimages were restored, with no repeated preference writes.

The actual bound VoiceAssist 1.3.24 editor reported an expired trial. Melodyne
5.4.2 required activation for editing. Neither was activated or given a new
trial. Sync Vx's subsequent functional Time qualification is recorded in the
additive supplement linked above, including its source-edge and preservation
limits. Installed third-party code pins stayed unchanged.

The 15.4 deployment target is a minimum executable requirement, not a claim that
all macOS builds are qualified. Runtime method signatures and owning images are
checked before activation. Foundation-only preference controls also passed on
macOS 26.2; that is not a normal Logic runtime qualification on that OS.

The final bundle changes only the bundled install guide and its resource seal.
Re-signing that seal updates the launcher executable's embedded code signature;
its Mach-O bytes outside the signature command/blob are identical, and the bridge
remains byte-identical. The final extracted, notarized ZIP opened the Sync Vx
fixture through its normal launcher UI and completed Save/Quit and cleanup with
all 2021 normal preference keys unchanged. The matching-settings cold render on this exact final signature passed.
