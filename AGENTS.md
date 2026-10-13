# AGENTS.md

Orientation for anyone (human or agent) picking this up cold. The README covers
what the app does and how to use it; this file covers what will **waste your time
if you do not know it**.

## Start here

```bash
./build.sh                 # required before anything else — see trap 1
./tools/selftest.sh        # 40 checks: audio pipeline
./tools/uitest.sh          # 52 checks: pixel assertions on the rendered window
```

Both suites must pass before claiming a change works. `./tools/uitest.sh` writes
PNGs to `TestOutput/` so you can look at the result.

## Traps that have already cost real time

### 1. `swift build` alone silently tests stale code

The app under test is `dist/Audio Editor.app`. `swift build` only updates
`.build/`. Lean on `swift build` and you will run the *previous* binary and get
a confident but meaningless pass. Always go through `./build.sh`.
`capture.sh` / `selftest.sh` / `uitest.sh` build first for this reason;
`AUDIOEDIT_SKIP_BUILD=1` opts out (used inside `uitest.sh` to build once).

### 2. Never pass test configuration on the command line

AppKit scans argv for `-flag value` pairs and treats any *leftover* token as "open
this document". That launch mode is fatal: **SwiftUI creates no window at all**,
so `onAppear` never fires and the harness does nothing. The symptoms are
confusing — the process stays alive, prints nothing, and `osascript ... count
windows` returns `0`. It is not a crash and not a hang in your code.

Configuration therefore goes through the environment, mapped by `capture.sh`:

| Variable | Meaning |
| --- | --- |
| `AUDIOEDIT_SNAPSHOT` | output PNG path — **presence is what enables the harness** |
| `AUDIOEDIT_FILE` | file to load |
| `AUDIOEDIT_TRIM` | `start,end` |
| `AUDIOEDIT_PLAYHEAD` | seconds |
| `AUDIOEDIT_UICHECK` | `1` to run pixel assertions |
| `AUDIOEDIT_LOUD` / `_QUIET` | `a-b,c-d` time ranges expected loud/silent |
| `AUDIOEDIT_SETTLE` | seconds to wait before capturing (default 1.0) |
| `AUDIOEDIT_SIZE`, `_BANNER`, `_LOOP` | window size, banner text, looping |
| `AUDIOEDIT_SELFTEST` | `:`-separated fixture paths |

Use `./tools/capture.sh <out.png> [--file ... --trim ... --playhead ... --uicheck]`
rather than assembling these by hand.

### 3. `AVAudioFile.read` throws at EOF

It does **not** return 0 frames at end of file — it throws `_GenericObjCError`.
Any read loop must cap the request to the frames remaining, or it loses the tail
of every file. This broke waveform analysis on most real audio. See
`WaveformPeaks.analyze` and `TrimmedAudioExporter.export`.

### 4. Debugging a GUI app launched by a script

Its stdout/stderr goes nowhere. Instead:

```bash
sample <pid> 2 -file /tmp/s.txt          # where is the main thread?
# in code: NSLog("[AudioEditor] ..."), then:
log show --last 2m --predicate 'process == "AudioEditor"' --style compact
launchctl setenv AUDIOEDIT_SNAPSHOT /tmp/x.png   # inject env into an `open -a` launch
open -a "dist/Audio Editor.app" TestAudio/x.wav
```

`launchctl setenv` is how you test the Finder "Open With" path end to end —
`open` does not inherit your shell environment. Remember to `launchctl unsetenv`.

### 5. Window capture has three independent traps

All three produce a plausible-looking image that is wrong:

- **Flipping.** Check `view.isFlipped` before applying a y-flip. SwiftUI's hosting
  view is flipped and needs one; the window's theme frame is not and does not.
  Getting it wrong silently mirrors the whole capture.
- **Transparency.** Fill the context with an opaque colour *before* rendering the
  layer tree. Uncovered window chrome is transparent, and a transparent PNG reads
  back as pure black — which corrupted every row-band calculation.
- **Inactive window.** macOS greys out prominent buttons and tint colours when the
  window is not key. Call `NSApp.activate()` + `makeKeyAndOrderFront` before
  capturing, or colour-based assertions fail for a reason that has nothing to do
  with your change.

### 6. Distrust any suite that can pass vacuously

The visual suite once printed `VISUAL CHECKS PASSED` having run **zero**
assertions, because `--uicheck` had been dropped from the invocations. A runner
that greps for success is not a runner that ran anything. `uitest.sh` now requires
both `snapshot: wrote` and `CHECKS PASSED` in the log. Keep that property.

### 7. Colour-based pixel assertions are fragile by nature

- Express thresholds **relative to the palette**, not absolutely. The waveform is
  painted in three brightnesses (accent / muted / muted-under-a-dark-overlay) and
  all three must be recognised; the dimmed variant is what broke the time mapping
  in every trimmed case.
- Measure bar height **outward from the plot's vertical midline**, not as a
  column's full ink extent. The ruler baseline is blue-ish, got classified as
  waveform ink, and inflated the measured envelope.
- **Exclude known elements before measuring.** Trim handles span the full plot
  rect (taller than the waveform), and the idle playhead renders at 55% opacity,
  which blends into a colour that squeaks past naive thresholds. Detect the
  playhead via its *opaque white marker* and exclude its columns.
- **Do not key checks off the system accent colour.** It is user-configurable (this
  machine is purple, value 5, not blue). The waveform palette is hardcoded, so
  waveform assertions are safe, but anything matching SwiftUI's `.accentColor` or
  `.tint` is not. The orientation check uses the fixed amber palette for this reason.
- Prefer a criterion that is independent of what you are trying to measure:
  handles are found by contiguous-amber-run length, which needs no plot geometry.

### 8. Xcode

Once installed and licensed, everything just works — `tools/common.sh` uses the
active toolchain. If the licence gate blocks the compiler (it needs an interactive
`sudo xcodebuild -license`), that script falls back to
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`, which is sufficient for this
package and needs no sudo.

## Where things are written down

| File | Holds |
| --- | --- |
| `docs/specs/SPEC.md` | Behavioural contract `G1`–`G40` and the constraining assumptions `A1`–`A8`. Cite these numbers in change specs. |
| `docs/specs/NNN-*.md` | Change specs against that baseline — each opens by naming the guarantees it alters. |

`./tools/checkspecs.sh` validates those specs: that cited `G`/`A` numbers exist (or are
declared as new by that spec), that links resolve, and that the impact header is present.
Renumbering a guarantee in `SPEC.md` silently invalidates every citation to it, so
**append new guarantees as `G41`, `G42`, … and never renumber**; the checker also fails if
the baseline numbering stops being contiguous.
| `AGENTS.md` (this file) | Traps, architecture invariants, deliberate decisions. |
| `README.md` | What the app is and how to use it. |

Before changing behaviour, check whether `docs/specs/SPEC.md` states it as a guarantee — if so,
the change must update that guarantee rather than quietly invalidate it. If a change
alters an `A`-row assumption, treat it as architectural and say so.

## Architecture

```
AudioDocumentModel        single source of truth: file, playhead, trim, status
ContentView               layout, drag-and-drop, banners
WaveformView              Canvas renderer, handles, scrubbing (never mutates the model)
AudioEngineController     AVAudioEngine playback of a sub-range, gapless looping
TrimmedAudioExporter      sample-exact trimmed WAV writer
SnapshotController        renders the window to PNG; drives the checks
SelfTest / UICheck        the two test suites
```

Invariants worth preserving:

- `AudioDocumentModel` owns all state; views are dumb and call back through
  closures. Do not let `WaveformView` reach into the model.
- Playback position is `segmentStartFrame + playerTime.sampleTime`, taken modulo
  the segment length when looping.
- `AVAudioPlayerNode.scheduleSegment` has **no `options:` parameter** (only
  `scheduleBuffer` does), so loop-forever is implemented by queueing one segment
  ahead from the completion handler rather than with a `.loops` flag.
- **A failed open must not modify state.** `AudioEngineController.load` prepares the
  replacement into locals and commits at the end; `AudioDocumentModel.load` does not
  clear anything until the engine has accepted the file. Reordering this back to
  "tear down, then open" silently makes a bad file destroy the user's work.
- Trim points become frames in exactly one place —
  `TrimmedAudioExporter.frameRange(...)`. The tests call it too, so the exporter
  and its verification cannot disagree about rounding.
- Export opens its own `AVAudioFile` and never shares the playback handle.

## Releasing

`tools/release.sh <version> [--draft|--publish]` builds a universal binary, packages
it, and creates the GitHub release. Verified facts worth not re-deriving:

- **Ad-hoc signing is not enough for distribution.** With the quarantine attribute a
  browser adds, macOS *kills* the app (`Killed: 9`), not merely warns. The only fix
  is a Developer ID signature plus notarisation.
- **A DMG does not avoid quarantine.** The app is clean on the mounted volume but
  picks quarantine up when dragged to /Applications.
- **`spctl --assess` is not the test.** It reports `rejected` even for a copy that
  launches fine — it assesses the signature, not the quarantine exception. To check
  whether something will actually run, run it.
- `ditto -c -k --sequesterRsrc --keepParent` is the correct way to archive a bundle;
  plain `zip` can drop extended attributes and the signature.
- Version stamps are applied to the *assembled* bundle, not to
  `Resources/Info.plist`, so the template stays clean.

## A regression test you have not seen fail is not yet a test

After adding a check, reintroduce the old behaviour and confirm the check **fails**.
This caught a real weakness in the `G4` work: 9 of the new checks failed against the
old code, and the two that passed revealed the exact inconsistency being fixed.

## Verifying a change

| Command | Covers |
| --- | --- |
| `./tools/selftest.sh` | read → analyse → export, across 16/24-bit, mono/stereo, 44.1/48 kHz, 0.35 s–3 min |
| `./tools/uitest.sh` | waveform drawn *and* positioned in time, handle/playhead positions, orientation, chrome |
| `./tools/capture.sh <png> --file ...` | a single state, for looking at |
| `./tools/inspect.sh <png> "<question>"` | advisory vision critique (needs network + image model; **not** a gate) |

Fixtures come from `swift tools/make-test-audio.swift` and encode known ground
truth (e.g. `bursts-44100-stereo16.wav` has audio only at 0.5–1.5 s, 3.0–3.4 s and
4.5–5.8 s). When adding a fixture, state its loud/silent ranges in `uitest.sh` so
the waveform position is actually asserted.

`tools/inspect.sh` sends a PNG to a vision model and prints a text critique. Use it
for judgement calls (does it read well?) — it needs the OpenRouter key in
`~/.pi/agent/auth.json`, so it is advisory only and must not gate a change.

## Deliberate decisions

- **`.wav` only.** Adding formats is one line in `AudioDocumentModel.load` plus a
  wider `allowedContentTypes`; everything downstream is format-agnostic.
- **A single `Window` scene, not `WindowGroup`.** A group opens an extra window
  every time the app receives a document-open event, so launching by double-click
  gave two windows.
- **macOS 15 floor**, needed for `defaultLaunchBehavior(.presented)`, without which
  a launch carrying a file comes up with no window.
- **MIT licensed.** Chosen over Apache-2.0 (no patent exposure in a waveform trimmer)
  and over copyleft (the goal is adoption, and GPL-3 would complicate App Store
  distribution later). The licence text is copied into the bundle at
  `Contents/Resources/LICENSE.txt` *before* codesigning — the signature covers bundle
  contents, so adding it afterwards would invalidate the signature.
- **No `-suppress-warnings`.** The build is warning-free; keep it that way rather
  than hiding new ones.