# Licence decision

**Decision:** MIT
**Date:** 2026-10-13
**Status:** adopted — see [`LICENSE`](../LICENSE), commit `e6b79ae`. GitHub detects it
as *MIT License*.

## Why MIT

### Not Apache-2.0

Apache's substantive advantage over MIT is an explicit patent grant. A waveform
trimmer has no patent exposure worth protecting, so Apache would add roughly 200 lines
of legalese plus `NOTICE`-file obligations for no practical benefit.

### Not GPL-3

Copyleft is the wrong tool for this project's goal. The aim is that people download and
use the app; GPL's purpose is to restrict what they may do with derivatives. More
concretely, **GPL-3 creates real friction with App Store distribution** — Apple's terms
conflict with GPL-3's anti-DRM and additional-restrictions clauses — and a Developer ID
is already under consideration, so that door is worth leaving open. MIT keeps it open.

### Not BSD-3-Clause

The difference is a no-endorsement clause covering use of the author's name in
promotion. Not a concern here, and MIT is more widely understood — it is what most
Swift and macOS open source uses.

## Implementation consequence: the licence has to ship inside the `.app`

MIT's actual requirement is that the copyright notice *travel with copies of the
software*. Because this project distributes **prebuilt binaries** from GitHub Releases,
that means the licence belongs **inside the `.app`**, not merely in the repository where
downloaders may never look.

`build.sh` therefore copies it to `Contents/Resources/LICENSE.txt`.

The ordering is load-bearing: **a code signature covers the bundle contents, so adding
a file after signing invalidates the signature.** The copy happens before `codesign`
runs, and the signature is verified afterwards. This is recorded in `AGENTS.md` so a
future change does not naively append files to the bundle.

`NSHumanReadableCopyright` was also set, so the About box reads *"Copyright © 2026
curiouslittledroid. MIT licensed."*

## Open items

1. **The copyright holder is currently `curiouslittledroid`** — the GitHub handle. It
   was chosen because the author deliberately keeps their email private. That is valid,
   but a copyright line ideally names a real person or entity, which matters if it ever
   needs enforcing. Changing it touches three places: `LICENSE`, `Resources/Info.plist`,
   and `README.md`.

2. **The live `v1.0.0` release predates the licence**, so its bundle contains no
   `LICENSE.txt`. Nothing is broken — the repository is licensed, so anyone taking the
   source gets it — but the binary and the repository are mildly inconsistent. Cutting
   `./tools/release.sh 1.0.1 --publish` would align them; otherwise the next release
   picks it up automatically.
