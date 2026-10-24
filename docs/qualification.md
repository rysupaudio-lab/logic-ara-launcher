# Historical RysUpPitch development qualification

This source-only alpha.2 record targets native ARM64 Logic Pro 12.4
(build 6707). Tests use synthetic 48 kHz sources and a private RysUpPitch
development candidate containing the ARA and stereo synthesis fixes. The
installed RysUpPitch 1.1.8 was not replaced. This launcher alone does not add
those plug-in fixes to a released binary.

The later native installable candidate uses separate normal-app and third-party
checks. See [current candidate results](normal-app-candidate.md) and
[its qualification data](normal-app-qualification.json). Do not combine this
development plug-in matrix with the third-party results.

## Stereo qualification

The stereo session contains six tracks, twelve regions and six four-second,
192,000-frame sources. Every case has a full region edited up one semitone and
a trimmed, reused-source region whose first visible note is edited down two
semitones. Cases cover proportional channels, independent left/right melodies,
anti-phase, left-only, right-only and quadrature audio.

| Check | Result |
| --- | --- |
| Exact host build/hash/signature admission and private-copy startup | Passed |
| Generic AUv2 ARA discovery, without product-specific archive or editor adapters | Passed |
| Actual ARA source samples | All twelve modifications matched original ordered-channel and mean fingerprints |
| Unedited native stereo baseline | Every channel matched its arranged source samples exactly |
| Native save and two cold process reopens | All 48 note IDs and pitch offsets restored exactly in both processes |
| Edited audio in each cold process | 60/60 channel-note components passed; maximum pitch error below 0.600 cents |
| Silent channels | 12/12 measurement windows passed in each cold process |
| Stereo phase and gain | 18/18 checks passed in each cold process |
| Previously failing quadrature trimmed note | Phase error −0.001165 radians, within unchanged 0.04-radian limit |
| Full mix vs. six actual isolated native stems | Passed PCM quantization bound without gain/delay fitting |
| Independent second-process repeat | Full mix and all six stems sample-identical; zero sample difference |
| Mixed mono/stereo regression on the same candidate | Four tracks/eight regions passed; all 32 saved note IDs/offsets restored in both cold processes |
| Mixed-session cold audio | 24/24 note components passed in each process; maximum pitch error below 0.922 cents |
| Mixed-session independent repeat | Full mix and all four stems sample-identical; zero sample difference |
| Launcher admission/ownership tests | 9/9 passed |
| RysUpPitch focused compatibility tests | 4/4 suites passed, including 470 stereo assertions |
| Licensed Melodyne editing, other plug-ins or Logic builds | Outside this historical matrix; see current candidate scope |

## What changed

Logic's shared ARA interface precreates regions using its first track's stream.
When that track is mono, the stale reader association can deliver
`[mean(original L, original R), original R]` from an otherwise stereo source.
The bridge now scopes the native stream-mode query to the exact two-channel
source read, preserving both original channels through Logic's own decoder.
Stored track modes and region links remain unchanged. No samples are reconstructed
from files or substituted by the bridge. See [the runtime design](design.md).

The RysUpPitch development candidate separately renders independent channels
with their own pitch geometry. Channels with verified matching fundamental pitch
and stable phase share complete synthesis timing while retaining their own
waveforms. Different melodies, detuned channels and unilateral material keep
independent timing. Shared render views cannot replace serialized source analysis.

The first stereo candidate passed pitch, source identity and repeatability but
failed the trimmed quadrature case at −0.078613 radians of phase error. That
failed control remains recorded. The corrected candidate passes the original
0.04-radian limit; the test was not relaxed. Direct regressions also cover reversed
channels, other phase offsets, note shifts and partial one-sided material.
At a partial silence boundary, the existing independent renderer can overlap the
next onset by 5.25 ms at approximately −81 dB peak. Stable silent interiors remain
zero; no hard-zero mask was introduced and no exact boundary-silence claim is made.

## Bounds and preservation

Audio comes from Logic's actual export engine with normalization disabled.
Measurements use isolated native solo stems, check changed and unchanged notes,
reject the old pitch at edited notes and compare the mix with the sum of stems.
These results establish the listed synthetic source/edit/save/recall cases on
these exact host and plug-in builds. They are not a listening assessment, stress
qualification, ARA conformance certification or a promise of arbitrary stereo
sessions, edit types, sample rates or third-party plug-in compatibility.

The installed Logic executable and qualified frameworks are hashed and
signature-verified before and after each run. Private copies are unregistered
and deleted only after their processes exit. The launcher never hides an app or
terminates a live Logic process. The private harness releases automation if a
non-test document appears or current document ownership cannot be verified.

The [current measured proof](stereo-qualification.json) contains both passing
matrices, sealed build hashes and the rejected earlier phase control without
local projects, binaries or personal paths. The [earlier mono evidence](qualification.json)
is historical alpha.1 evidence; its stereo failure describes the old reader and
candidate.
