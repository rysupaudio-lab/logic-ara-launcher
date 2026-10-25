# Sync Vx Time qualification supplement

The **unchanged published 0.2.0-candidate.5 app** passed a bounded Waves Sync Vx
17.1.42 Time workflow in native ARM64 Logic Pro **12.4 (6707)** on **macOS 27.0
(26A428)**. This adds evidence to the original publication-time qualification;
the tag, installers and four original release assets remain immutable.

Two normal first-slot mono ARA inserts displayed the actual vocal source rows and
waveforms. One track was REF 1 and the other Sync 1. The vendor editor reported
**IN SYNC**. With Pitch off, enabling Time / TimeWarp A / 100 changed 562,186 decoded
sample values compared with Time off (maximum 0.4717943668; RMS 0.0617043129).
Two Time-on warm exports matched exactly. Turning Time off reproduced the initial
Time-off export exactly. Normal native Save wrote the genuine Sync Vx ARA archive
and eight source/region map pairs.

Two independent cold processes opened byte-exact copies of the immutable edited
warm save through the normal launcher. Both recalled REF/Sync assignments, enabled
Time and IN SYNC. Each normal offline export was **sample-identical to the edited
warm export and to the other cold export**: 408,000 stereo frames, 48 kHz/24-bit,
zero changed values, maximum/RMS difference zero. Decoded PCM32 SHA-256:
`ad30a6fcfb749174c47b2cd247deb1b1edd1551b03c66dbf12226b6fd8e36ff6`.
Both used the exact published launcher `33af251f…` and bridge `c32dd4aa…`.

## Retained limits

- The normal host-bypass export matched the current vocal arrangement reconstructed
  from saved native clip geometry and gain/pan words within one 24-bit LSB across
  the entire export. No gain/delay fit or excluded interval was used. This is not
  an exact live ARA source-buffer fingerprint measurement.
- **Time off was not transparent to host bypass at region edges:** 2,302 decoded
  values differed, maximum 0.0938868523 and RMS 0.0019696349. This criterion remains
  a failure; it is not hidden by trimming or a tolerance pass.
- The opaque Sync archive reserialized from 13,701 to 13,582 bytes after cold Save.
  Warm/cold archive byte identity is not claimed. Both cold-saved archives and AU
  records matched each other; actual recalled UI and native audio prove the bounded
  result without interpreting proprietary archive contents.
- Sync Vx Pitch, other algorithms, arbitrary sessions, other OS/host builds and ARA
  conformance remain unqualified. The earlier autochoir mixed-Formant warm/cold
  failure remains unchanged.

## Preservation

All owned Logic and launcher processes exited normally and private copies/locks
were removed. Original Logic signature/code pins and 27 recorded installed
third-party code/metadata pins stayed unchanged. Global audio-device defaults
stayed unchanged. No activation, trial, signature repair, force quit, signals,
Don't Save or hardware playback was used. Existing Waves ad-hoc/strict-invalid
signature status was preserved without repair or bypass.

The two shared macOS navigation-history keys remain an exception to private
preference routing. Warm testing issued one guarded restoration batch for known
preimages; the first readback refused a transient mismatch, and later read-only
verification found all 2,021 baseline keys exact. No writes were repeated.
During cold 1, a separate installed Logic process ran concurrently. Four normal
preference values outside the navigation whitelist changed; causal attribution
is unqualified. Restoration refused **before any write**, preserving unknown
changes. Cold 2 then preserved all 2,021 values of its fresh baseline exactly,
with no restoration writes. Do not describe the whole three-process test as
leaving every normal preference unchanged.

The patch uses **private Apple host interfaces**. Third-party tests used normal
vendor UI and public ARA interfaces, with no private third-party plug-in API.
No project, audio, vendor archive, private helper, license, process ID or private
path is included in this supplement. See the
[machine-readable result](syncvx-time-qualification.json) and
[current support matrix](normal-app-candidate.md).
