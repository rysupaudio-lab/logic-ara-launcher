# Qualification and limits

This is an experimental source-only alpha for native ARM64 Logic Pro 12.4
(build 6707). Tests ran on macOS 27.0 (26A428), with 48 kHz synthetic sources and
a private RysUpPitch development candidate containing the ARA compatibility fixes.
The public/installed RysUpPitch 1.1.8 was not replaced by these tests.

The test session contains four tracks, eight regions and four sources. The
qualified audio scope is **three mono tracks and seven independent regions**:
sequential and reused sources, trimmed source ranges, and overlapping tracks.
Each source contains 192,000 frames. The fourth track tests proportional stereo
and exposes the host-reader limitation below; it does not count as a stereo pass.

| Check | Result |
| --- | --- |
| Exact host build/hash/signature admission and private-copy startup | Passed |
| Generic AUv2 ARA discovery, without product-specific archive or editor adapters | Passed |
| Real ARA source acquisition | Eight modifications, four sources, one controller |
| Opposite edits on regions reusing the same source | Native model and save readback passed |
| Native archive restoration | Both cold processes restored all 32 stored note IDs/offsets exactly |
| Mono audio after cold reopen | Both processes: 22/22 note components passed; maximum pitch error 0.922 cents |
| Mixed output vs. four actual isolated stems | Both processes passed PCM quantization bound |
| Independent second-process repeat | Mix and all four stems were sample-identical across two cold processes |
| Launcher admission/ownership tests | 9/9 passed |
| RysUpPitch focused compatibility tests | 3/3 suites, 41 assertions passed |
| Stereo image | Failed; unsupported by this alpha |
| Licensed Melodyne editing, other plug-ins or Logic builds | Untested |

## Stereo limitation

The stereo source declares two channels, and its live AU reports two input and
two output channels with no render error. Nevertheless, the samples delivered
through the ARA host-reader path have an exact fingerprint matching
`[mean(original L, original R), original R]`. The output therefore has the wrong
stereo image. A two-channel AU configuration alone is not sufficient evidence of
correct stereo ARA access. This alpha does not patch that reader or attempt to
reconstruct arbitrary stereo audio.

The plug-in candidate separately refuses independently varying stereo edits;
proportional-channel preservation is covered by its direct-host tests. That does
not remove the Logic host-reader limitation. Use mono test sources only here.

## What these results establish

The audio comes from Logic's actual export engine, with normalization disabled.
Measurements use isolated native solo stems, verify both changed and unchanged
notes, reject the old pitch at edited notes, and compare the mix with the sum of
the stems without gain/delay fitting. These are bounded synthetic-audio checks,
not a listening assessment, stress qualification, ARA conformance certification,
or a promise that every plug-in works.

The installed Logic executable and both qualified frameworks are hashed and
signature-verified before and after each run. Private copies are unregistered
and deleted only after their processes exit. The launcher never hides an app or
terminates a live Logic process. The private test harness releases automation if
a non-test document appears or current document ownership cannot be verified.

[Machine-readable measured evidence](qualification.json) includes the checks, hashes
and cold-render comparison without local projects, binaries or personal paths.
