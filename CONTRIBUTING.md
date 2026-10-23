# Contributing

Please report the Logic version/build, macOS version, Mac architecture, plug-in
name/version and exact steps. Remove personal paths and project names before
sharing logs. Never attach Logic or commercial plug-in binaries, licensed audio,
activation data, crash dumps containing private projects, or proprietary sources.

Support for a new host build requires inspected object layouts, symbol and vtable
checks, full framework hashes and a new disposable-copy qualification. Do not
weaken existing guards to admit an untested build. Plug-in compatibility fixes
should go upstream to the plug-in rather than replacing archive identity or
redirecting editor views inside this launcher.

Use 48 kHz synthetic source material for reproducible qualification. Include actual
host source acquisition, edit isolation, host save/cold reopen and host-rendered
audio evidence. A successful ARA factory lookup alone is insufficient.
