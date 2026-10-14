# 002 — Loop range survives a mid-selection resume

**Baseline:** [`SPEC.md`](SPEC.md) — written against `G1`–`G47`.
**Status:** implemented.
**Date:** 2026-10-13

```
Changes:    none — this restores G17, which the code had been violating
Preserves:  G13–G23, G24, G41–G47, A1, A7
Adds:       none
Removes:    none
New checks: selftest gains partial-pass composition checks and a loop-range
            anchoring check that fails against the old code
```

## The bug

With looping on, adjusting a fade while playing narrowed the loop until it cycled
over just the fade-out window.

Rescheduling playback passed the **playhead** as the play call's start, and the
engine treated that start as the loop start. Every resume therefore defined a new
loop of `[playhead, trimEnd]`, and because `currentTime` reported a position inside
that window, the next resume started there again. Editing the fade-out moved the
resume point closer to `trimEnd` with each keystroke, so the loop shrank monotonically
toward the fade-out window — which is what the user saw.

`Playback`'s `G17` says looping repeats `[trimStart, trimEnd]`, and `G22` says a loop
toggle resumes from the current position rather than restarting. Both can hold at once
only if the loop start is **independent of where a pass resumes**, and the code had no
such concept: `play(from:to:looping:)` conflated them.

## The fix

`AudioEngineController.play` gains an explicit `loopStart`, separate from the pass
start:

- The loop range is `[loopStart, end]`; passes after the first always cover all of it.
- The first pass may begin part-way through (`beginOffset`), so playback resumes from
  the current position (`G22`) without redefining the loop (`G17`).
- `loopRangeFrames` exposes the range the engine actually repeats, so the property is
  testable rather than inferred.
- `currentTime` is linear across a partial first pass, then cycles over the full range.

`AudioDocumentModel` routes every (re)schedule through one `schedulePlayback(from:)`
helper, which passes `loopStart: trimStart` whenever looping. That single choke point is
what stops any future resume path — seek, loop toggle, trim commit, fade edit — from
reintroducing the bug.

The fade envelope is computed against the **whole** selection even for a partial pass,
so resuming inside a fade picks up the correct gain instead of restarting the ramp. A
resume inside the fade-out therefore emits a shortened tail buffer whose first sample
carries the mid-fade gain.

## What this changes for the user

| | Before | After |
| --- | --- | --- |
| Adjust a fade while looping | Loop collapses to the fade-out window | Loop still spans the selection |
| Seek while looping | Loop becomes `[seek, trimEnd]` | Loop still spans the selection |
| Enable loop mid-playback | Loop becomes `[position, trimEnd]` | Resumes from the position, then loops the selection |

## Checks

`tools/selftest.sh`:

- A pass resumed past the fade-in emits the untouched middle segment, not a fade-in
  buffer, and covers exactly the remainder (segment start contiguous with the previous
  item, total frames exact).
- A pass resumed inside the fade-out is a single shortened tail whose first sample is
  the source times the mid-fade gain — i.e. the envelope continues rather than restarts.
- A loop begun at the selection start reports `loopRangeFrames == selection`.
- **A looping resume keeps the full loop range (`G17`).** Confirmed to fail against the
  old code: `Optional(ClosedRange(5710...6945)) vs 3858...6945` — the resume window
  rather than the selection.
- A non-looping pass reports no loop range.

selftest 115 → 123. `uitest.sh` unchanged (75) — this is behaviour with no new pixels.

## Preserved

`G46` still holds: with both fades at 0 ms the non-looping schedule is the same single
segment as before, and `loopStart` only affects looping. The no-fade looping path still
queues two whole-selection segments.
