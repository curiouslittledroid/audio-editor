# Audio Editor

A small native macOS audio trimmer. Open a `.wav`, see its waveform, play it with a
progress marker sliding across, drag the in/out points to trim the start or end, and
save the kept region to a new `.wav`.

Built with SwiftUI + AVFoundation, compiled by Swift Package Manager, and wrapped
into a real `.app` bundle — no Xcode project required.

> Working on the code? Read two files first:
> **[docs/specs/SPEC.md](docs/specs/SPEC.md)** — the numbered behavioural contract
> (G1–G40) plus the load-bearing assumptions (A1–A8) that change specs cite as their
> baseline, with proposed changes in `docs/specs/`.
> **[AGENTS.md](AGENTS.md)** — the traps that are expensive to rediscover (stale
> bundles, why test config can't go on the command line, window-capture flipping,
> `AVAudioFile.read` at EOF).

## Build & run

```bash
./build.sh              # release build -> dist/Audio Editor.app
./build.sh release run  # build and launch
```

Then either launch `dist/Audio Editor.app`, or:

```bash
open "dist/Audio Editor.app"
```

## Using it

| Action | How |
| --- | --- |
| Open a file | Drag a `.wav` from Finder onto the window, `⌘O`, **Open**, or Finder ▸ Open With (double-click works too) |
| Play / pause | **Space**, or the ▶ button |
| Seek | Click or drag anywhere on the waveform |
| Trim the start | Drag the **left amber handle**, or park the playhead and press **Set In** (`⌥I`) |
| Trim the end | Drag the **right amber handle**, or press **Set Out** (`⌥O`) |
| Loop the selection | `⌘L`, or the ⟳ button |
| Save the trim | `⌘E` / **Export Trimmed** → writes `<name>-trimmed.wav` |
| Undo the trim | **Reset** (or `⇧⌘A`) |

The kept region is drawn in blue; the parts that will be discarded are dimmed.
`IN`, `OUT` and `KEPT` readouts along the bottom show the exact times.

Export preserves the source sample rate, channel count, bit depth and endianness,
and the written samples are verified sample-exact against the source.

## Publishing a release

```bash
./tools/release.sh 1.0.0              # build + package + verify (no network access)
./tools/release.sh 1.0.0 --draft      # also create a draft GitHub release to review
./tools/release.sh 1.0.0 --publish    # create and publish it
```

Produces a **universal** (Apple Silicon + Intel) build in `dist/release/`: a `.dmg`
with an Applications shortcut, a `.zip`, and `SHA256SUMS.txt`. The script verifies
the signature, both architectures, the stamped version, the declared `.wav`
handling and that the app actually launches before it packages anything.

### The Gatekeeper problem — read before publishing

The app is **ad-hoc signed**, because this machine has no Developer ID certificate.
That means **every downloader will be blocked on first launch**. Measured on macOS
26.5.1 with the quarantine attribute a browser adds:

| Delivery | What happens |
| --- | --- |
| `.zip` | quarantine propagates to the extracted app; launching it gets `Killed: 9` |
| `.dmg` | clean on the mounted volume, but the app gains quarantine when dragged out |
| after approval | runs normally |

macOS shows *"Apple cannot check 'Audio Editor' for malicious software"*. The user
must approve it once via **System Settings → Privacy & Security → Open Anyway**.
Control-click → Open is no longer part of Apple's documented flow.

A technical user can instead clear the attribute, which is verified to work:

```bash
xattr -dr com.apple.quarantine "/Applications/Audio Editor.app"
```

Beware when testing this yourself: `spctl --assess` keeps reporting `rejected` even
for a copy that launches fine, because it assesses the signature rather than the
per-file quarantine exception. Judge by whether the app runs.

### Removing that friction

Only a **Developer ID signature plus notarisation** avoids the prompt, which needs an
Apple Developer Program membership (US$99/year):

1. Obtain a *Developer ID Application* certificate.
2. `export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"` — `build.sh`
   then signs with the hardened runtime instead of ad-hoc, and fails loudly if the
   identity is wrong rather than quietly producing an ad-hoc build.
3. Notarise and staple:
   ```bash
   xcrun notarytool store-credentials <profile>        # once
   xcrun notarytool submit dist/release/AudioEditor-1.0.0-macos-universal.zip \
       --keychain-profile <profile> --wait
   xcrun stapler staple "dist/Audio Editor.app"
   ```

Steps 2–3 are documented rather than automated, because neither can be tested on a
machine without a certificate.

### Or just ship the source

For a project this size, `git clone && ./build.sh release run` takes about ten
seconds and sidesteps the trust question entirely. If asking people to override
their security settings is unappealing, linking to the source may be the better
default.

## Layout

```
Sources/AudioEditor/
  AudioEditorApp.swift        @main, menu bar, Finder open-with, self test entry
  ContentView.swift           header / waveform / transport layout, drag-and-drop
  AudioDocumentModel.swift    single source of truth: file, transport, trim state
  WaveformView.swift          Canvas renderer, trim handles, scrubbing playhead
  WaveformPeaks.swift         min/max downsampling for display
  AudioEngineController.swift AVAudioEngine playback of a sub-range, gapless looping
  TrimmedAudioExporter.swift  sample-exact trimmed WAV writer
  SnapshotController.swift    renders the window to PNG / runs UI checks
  SelfTest.swift              headless audio pipeline checks
  UICheck.swift               pixel assertions on the rendered window
  TestReporter.swift          shared pass/fail reporting
docs/specs/SPEC.md            behavioural contract G1-G40, assumptions A1-A8
                              docs/specs/001-*.md  change specs against that baseline
AGENTS.md                     traps, architecture invariants, deliberate decisions
tools/
  common.sh                   shared env: paths + Swift toolchain selection
  make-test-audio.swift       generates the .wav fixtures
  selftest.sh                 runs the audio pipeline checks
  uitest.sh                   runs the visual regression checks
  release.sh                  packages and publishes a GitHub release
  capture.sh                  renders one PNG of any state
  inspect.sh                  sends a PNG to a vision model for a written critique
```

## Testing

Two independent layers. The first is arithmetic and gates changes; the second is a
judgement call about design.

### Audio pipeline — `./tools/selftest.sh`

```bash
swift tools/make-test-audio.swift   # once, to create TestAudio/
./tools/selftest.sh
```

Runs the whole read → analyse → export path over every fixture (16/24-bit,
mono/stereo, 44.1/48 kHz, 0.35 s to 3 min): reading, waveform analysis, and an
export round trip checking duration, preserved format, and sample-exact equality
with the source over the trim range. 40 checks.

### Visual regression — `./tools/uitest.sh`

Renders the real window in five states and asserts on the resulting pixels. 52
checks, no vision model, fully reproducible.

- The plot area is discovered from the waveform's own pixels, so a layout shift
  cannot make the checks pass vacuously.
- Waveform bar height per column is measured outwards from the plot's vertical
  midline, and compared against times where each fixture is known to be loud vs.
  silent — verifying the waveform is drawn *and* positioned correctly in time.
- Both amber trim handles must land on the requested in/out times (measured
  accurate to ~0.03 s), and the playhead on its requested time.
- Amber ink must sit below the plot and not above it, which catches a vertically
  mirrored render — a real bug this caught during development.
- Neither the header nor the transport bar may be blank.

PNGs land in `TestOutput/` for eyeballing.

Because the app captures its own layer tree, none of this needs Screen Recording
permission.

### Written critique — `./tools/inspect.sh`

For the things arithmetic cannot judge (does it read well, is anything awkward),
a rendered PNG can be sent to a vision model that returns a text critique:

```bash
./tools/capture.sh /tmp/shot.png --file TestAudio/bursts-44100-stereo16.wav \
    --trim 1.0 4.5 --playhead 2.5
./tools/inspect.sh /tmp/shot.png "Report any clipping, overlap or misalignment."
```

Uses the OpenRouter key in `~/.pi/agent/auth.json`; override the model with
`VISION_MODEL=...`. This layer is advisory — it needs network access and a model
that supports images, so it is not part of the pass/fail gate.

### `capture.sh`

```bash
./tools/capture.sh <out.png> [options]
  --file <wav>         load a file          --trim <start> <end>
  --playhead <sec>     place the playhead   --loop
  --size <WxH>         window size          --banner "error:msg" | "info:msg"
  --uicheck            also run pixel assertions
  --loud  a-b,c-d      times expected loud   --quiet a-b,c-d   times expected silent
```

> Test configuration is passed through the **environment** (`AUDIOEDIT_*`), not
> argv, and `capture.sh` handles the mapping. This is deliberate: AppKit parses
> `-flag value` pairs out of the argument list and treats a leftover token as
> "open this document", which puts the process into a launch mode where SwiftUI's
> `WindowGroup` never creates a window — so the harness silently never ran.

## Licence

[MIT](LICENSE) © 2026 curiouslittledroid.

Free to use, modify and redistribute, including commercially. The only requirement is
that the copyright notice and licence text travel with the software, which is why the
built `.app` carries a copy at `Contents/Resources/LICENSE.txt`. There is no warranty.

MIT rather than Apache-2.0 (patents are not a concern for a waveform trimmer) and
rather than a copyleft licence (you want people to download and use this, and GPL-3
would complicate any future App Store distribution).

## Requirements

- macOS 15 or later (`defaultLaunchBehavior(.presented)` is used to guarantee the
  window appears on a document-open launch)
- A Swift 5.9+ toolchain. Scripts use whichever is active — Xcode if installed and
  licensed, otherwise Command Line Tools, which are sufficient on their own.

## Scope

`.wav` (and `.wave`) input only, as a deliberate starting point. Other formats that
`AVAudioFile` can read are a one-line change in `AudioDocumentModel.load` plus a
wider `allowedContentTypes`; the UI, waveform and export paths are format-agnostic.