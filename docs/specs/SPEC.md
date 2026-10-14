# SPEC.md — behavioural contract

What this app guarantees **today**, stated precisely enough to be contradicted.

This is the baseline that change specs refer to. Its value is not describing the app
(browse the UI for that, or read `README.md`) — it is making the implicit explicit, so
a future change can say *"this changes G14, preserves everything else"* and be checked
against something.

**House rules**

- Guarantees are numbered `G<n>` and grouped. Cite them by number in change specs.
- A guarantee is only worth writing down if it could be violated without anyone
  noticing. The obvious surface is not repeated here.
- Where an automated check enforces a guarantee, it is listed in
  [Traceability](#traceability). Where nothing enforces it, it says so — that is the
  point of the table.

Architecture, code layout, build mechanics and testing traps live in
[AGENTS.md](../../AGENTS.md), not here.

---

## Scope

**Does:** open a `.wav`, draw its waveform, play a sub-range with a moving playhead,
choose that sub-range by dragging handles, write it to a new `.wav`.

**Explicitly does not:** edit destructively, mix, apply effects or gain, fade, normalise,
resample, support more than one open file, support more than one contiguous selection,
zoom, undo, or render offline.

---

## Opening

| | Guarantee |
| --- | --- |
| **G1** | Accepts files whose extension is `wav` or `wave`, compared case-insensitively. |
| **G2** | Any other extension is refused with an error naming the extension. |
| **G3** | Opening a file replaces the current one entirely: playhead at 0, selection set to the whole file, waveform discarded and re-analysed. |
| **G4** | Refusing a file — **for any reason**, unsupported type or undecodable content — leaves the current document exactly as it was: same file, same selection, same playhead, same waveform, playback uninterrupted. |
| **G5** | A refused open reports an error naming the file, never leaves a partially-adopted document behind, and never interrupts playback of the current file. Adoption is atomic: nothing is cleared or torn down until the new file is known to be readable *and* playable. |
| **G6** | Waveform analysis never blocks the main thread. |
| **G7** | If a newer file is opened while analysis is still running, the stale result is discarded rather than applied. |

## Display

| | Guarantee |
| --- | --- |
| **G8** | Peak data is `~500 buckets per second`, clamped to 2000–30000 buckets. |
| **G9** | Multichannel audio is mixed to one display lane by arithmetic mean; channel count is reported in the header. |
| **G10** | Every bucket is given a minimum visible height (half-height ≈ 0.0008), so silence renders as a hairline rather than a gap. |
| **G11** | The ruler picks its tick interval from a fixed ladder targeting ≈1 tick per 95 pt, so ticks never collide. |
| **G12** | Time-to-x mapping spans the full plot width and is linear; the same mapping is used for the waveform, handles and playhead. |

## Playback

| | Guarantee |
| --- | --- |
| **G13** | Playback is confined to `[trimStart, trimEnd]`; the rest of the file is never audible. |
| **G14** | Asking to play with the playhead outside the selection starts from `trimStart`. |
| **G15** | The playhead is derived from the audio render clock, so it stays in step with what is audible rather than drifting with wall time. |
| **G16** | Reaching the end of the selection stops playback and parks the playhead at `trimEnd`. Pressing play then restarts from `trimStart`. |
| **G17** | Looping repeats `[trimStart, trimEnd]` with no dropout at the seam. |
| **G18** | Seeking while playing re-schedules audio from the new position immediately. |
| **G19** | Seeking to at or after `trimEnd` while playing restarts from `trimStart`. |
| **G20** | Seeking while paused only moves the marker; it does not start playback. |
| **G21** | Dragging a trim handle while playing does not disturb audio mid-drag; audio re-schedules once the drag ends. |
| **G22** | Changing the loop toggle while playing resumes from the current position rather than restarting. |
| **G23** | Stop halts playback and returns the playhead to `trimStart`. |

## Trimming

| | Guarantee |
| --- | --- |
| **G24** | The selection is a single contiguous range `[trimStart, trimEnd]` inside `[0, duration]`, defaulting to the whole file. |
| **G25** | The selection can never be shorter than 5 ms; dragging a handle past its partner clamps rather than inverting the range. |
| **G26** | `trimStart` clamps to `[0, trimEnd − 5 ms]`; `trimEnd` clamps to `[trimStart + 5 ms, duration]`. |
| **G27** | Moving a boundary past the playhead drags the playhead along, so the playhead is always inside the selection or exactly on its edge. |
| **G28** | Grabbing within 11 pt of a handle moves that handle; anywhere else on the waveform seeks. |
| **G29** | A drag that begins as a handle drag stays that handle for its duration, even if the pointer moves away. |
| **G30** | Reset restores the selection to the whole file and clears both fades. |
| **G31** | Trimming is non-destructive; nothing is written until an export. |

## Export

| | Guarantee |
| --- | --- |
| **G32** | Writes a new file and never modifies the source. |
| **G33** | Time in seconds becomes a frame range by rounding to the **nearest** sample, and that conversion happens in exactly one place so the exporter and its tests cannot disagree. |
| **G34** | Sample rate, channel count, bit depth and endianness are preserved from the source; the container is always LinearPCM WAV. |
| **G35** | Exported samples are identical to the source over the same range, multiplied by the fade envelope, which is 1 outside the fade regions. With both fades at 0 ms the output is bit-identical to a no-fade export. |
| **G36** | An empty selection is reported as an error, never a silent no-op or a zero-byte file. |
| **G37** | Export runs off the main thread and the UI shows an in-progress state. |
| **G38** | Export does not interrupt playback. |
| **G39** | The suggested filename is `<base>-trimmed.wav`. |
| **G40** | Success reports the saved name and duration and offers to reveal it in Finder. |

## Fades

| | Guarantee |
| --- | --- |
| **G41** | A fade multiplies every channel by the same linear gain ramp: fade-in rises 0→1 across `[trimStart, trimStart + fadeIn]`, fade-out falls 1→0 across `[trimEnd − fadeOut, trimEnd]`. Both endpoints are inclusive — the first sample of a fade-in is exactly 0, and the last sample of a fade-out is exactly 0. |
| **G42** | Fades never overlap; each is clamped to at most half the selection, counted in frames. |
| **G43** | Fade durations are re-clamped when the selection shrinks or a new file loads, so the field always displays the value actually applied. |
| **G44** | The waveform panel draws the fade envelope using the same time-to-x mapping as the waveform, handles and playhead. |
| **G45** | Samples outside the fade regions are unmodified. |
| **G46** | With both fades at 0 ms, exported output is bit-identical to a no-fade export of the same selection. |
| **G47** | Playback applies the same fade envelope as export, so a fade is audible during preview. A pass is scheduled as `[faded head][middle segment][faded tail]`, using the one `fadeGain`/`applyFade` implementation the exporter uses; with both fades at 0 ms the single-segment schedule is used unchanged. |

Fades are applied on export, drawn on the waveform, **and heard during preview**.

---

## Assumptions that constrain future work

These are not guarantees — they are the load-bearing simplifications. Changing one is
an architectural change, not a feature.

| | Assumption | Cost of breaking it |
| --- | --- | --- |
| **A1** | **One contiguous selection.** | Cutting out a middle section, or keeping several regions, means replacing `trimStart`/`trimEnd` with a list of ranges, and reworking handle hit-testing, the dimming/shading in `WaveformView`, and the exporter loop. This is the single biggest structural constraint. |
| **A2** | One file at a time; the audio engine is rebuilt per file. | Multiple open files needs engine lifecycle and state per document. |
| **A3** | `.wav` only. | Cheap: one gate in `AudioDocumentModel.load` plus `allowedContentTypes`. Display and export are already format-agnostic. |
| **A4** | No undo. Reset is the only way back. | Undo needs command objects or a state snapshot per mutation — currently every trim edit mutates in place. |
| **A5** | Peaks are computed once per load at a fixed resolution. | Zoom, or re-analysis on resize, needs a resolution pyramid and a cache keyed by zoom level. |
| **A6** | The whole file is read to build peaks. | Analysis memory scales with duration × channels. Very long files will need streaming or a peak cache on disk. |
| **A7** | Playback is realtime through the default output device. | Offline rendering, or output-device selection, breaks the "position comes from the render clock" model in `AudioEngineController`. |
| **A8** | **Exactly one kind of processing: linear fades at the selection boundaries.** | Everything else — gain, normalisation, EQ, compression — still belongs in the exporter's read loop and must still not be applied on the display path, or the waveform will lie about the output. Fades are the exception that proves the rule: they are drawn as an *envelope* rather than by rescaling the waveform, so the display still tells the truth about source amplitude and applied gain separately. |

---

## Traceability

Which guarantees an automated check actually enforces today.

| Suite | Guarantees covered |
| --- | --- |
| `tools/selftest.sh` (123 checks) | G1–G5 (open/refuse semantics, incl. atomic adoption), G17 (loop range survives a mid-selection resume), G33–G36, G39, G41–G43, G45–G47 |
| `tools/uitest.sh` (102 checks) | G10, G12 (waveform drawn and positioned in time), G24, G26, G28, G30 (handle positions), G15, G18 (playhead position), G41, G44 (fade envelope present, positioned, and linear), and — beyond any listed guarantee — that the transport readouts stay on one line at the minimum window width |

### Not enforced by any check — regressions can slip through here

| | Guarantee | Why it matters |
| --- | --- | --- |
| G13, G14, G16, G19 | selection-only playback, restart behaviour | Core promise of a trimmer; currently only manual. |
| G21, G22 | behaviour while playing | Interaction bugs that are awkward to test, but users hit them. |
| G25, G27 | clamping, playhead coupling | Off-by-one at the boundaries is silent. |
| G29 | drag stickiness | Only reproducible with real pointer movement. |
| G38 | export during playback | Untested interaction between two file handles. |
| G9, G11 | display correctness | Cosmetic, but silently wrong. |

Closing the playback rows is the cheapest high-value testing win: `AudioEngineController`
exposes `currentTime` and the segment bounds, so the range, restart and loop behaviour
are all assertable headlessly without a window.
---

## Known warts

Documented rather than silently fixed, so they can be decided on deliberately.

| | Issue |
| --- | --- |
| **W1** | The `AUDIOEDIT_*` test harness and `--selftest` ship inside the app binary. Harmless, but it is production code carrying test scaffolding. |

---

## Using this with a change spec

A change spec (for example `docs/specs/001-fade-in-out.md`) should open by naming what it
touches:

```
Changes:    G35 (samples are no longer unconditionally identical to the source),
            G30 (Reset clears fades), A8 (the app now processes audio) — ARCHITECTURAL
Preserves:  G24, G31 (still non-destructive), G33, G34 (format unchanged)
Adds:       G41–G46
Removes:    none
New checks: selftest gains the fade envelope, clamping and model-state checks;
            uitest gains a fade-envelope rendering check
```

If a proposal cannot say which guarantees it changes, it is not yet understood well
enough to implement. If it changes an **A**-row, treat it as an architectural change and
say so explicitly.