# 001 — Fade in / out

**Baseline:** [`SPEC.md`](SPEC.md) (contract `G1`–`G40`, assumptions `A1`–`A8`)
**Status:** proposed — not implemented
**Date:** 2026-10-13

```
Changes:    G35 (samples are no longer unconditionally identical to the source)
            G30 (Reset also clears fades)
            A8  (the app now performs exactly one kind of processing) — ARCHITECTURAL
Preserves:  G24, G31, G33, G34, G36–G40, G12, G26–G29, A1
Adds:       G41–G46 (below)
Removes:    none
New checks: selftest gains fade-envelope, clamping and no-op checks;
            uitest gains a fade-envelope rendering check
```

> `A8` is an assumption row, so per SPEC.md this is an **architectural** change, not a
> feature: the app stops being a pure pass-through. That is called out rather than
> quietly absorbed.

## Summary

Add an independent linear fade-in and fade-out at the selection boundaries. Fades are
non-destructive properties of the selection, applied when exporting and drawn on the
waveform, so the user can soften clicks and pops at the edges of a sample.

Motivated by the project's stated use — preparing one-shots for samplers, where a hard
edge at the trim point produces an audible click.

## Behaviour

### Parameters

Two durations, stored in seconds, presented in **milliseconds to one decimal place**
(a 10 ms fade should read `10.0 ms`, not `0:00.010`). Both default to **0**, so the
feature is opt-in and every existing behaviour is unchanged until a fade is set.

Independent in/out values, not a single symmetric control: trimming a click off the
front and a tail off the end are different jobs.

### The envelope, exactly

Frame range comes from the existing single rule (**G33**), so fades are sample-exact and
cannot drift from the export range:

```
L            = endFrame - startFrame
fadeInFrames  = clamp(round(fadeInSeconds  * sampleRate), 0, floor(L / 2))
fadeOutFrames = clamp(round(fadeOutSeconds * sampleRate), 0, floor(L / 2))
```

Gain for the sample at offset `i` in `[0, L)`, applied identically to every channel:

| Condition | Gain |
| --- | --- |
| `i < fadeInFrames` | `fadeInFrames == 1` ? `0` : `i / (fadeInFrames - 1)` |
| `i >= L - fadeOutFrames` | `j = i - (L - fadeOutFrames)`; `fadeOutFrames == 1` ? `0` : `1 - j / (fadeOutFrames - 1)` |
| otherwise | `1` |

Both endpoints are inclusive, which makes the guarantees testable: **the first sample of
a fade-in is exactly 0, and the last sample of a fade-out is exactly 0.** The
single-frame case is defined rather than left to divide by zero.

Because each fade is clamped to `floor(L/2)`, the regions can never overlap, and when
they exactly meet the gain is continuous across the join (1 on both sides).

### Clamping

`G42`/`G43`: the *stored* durations are clamped whenever the selection shrinks or a new
file loads, so the field always displays the value actually applied.

The alternative — remember the requested value but apply a smaller one — is rejected
because the field would then lie about the output, which is the same objection `A8`
raises about processing on the display path. The cost is that shrinking then re-expanding
the selection does not restore a larger fade; setting the fade after the trim is the
natural order of work, so this is acceptable.

### Display

The waveform's peaks are computed once per load from the **unfaded** source (`G8`), so
under a fade the drawn waveform does not shrink. That is only honest if the applied gain
is shown too, so the panel draws the **envelope** as a line over the waveform (rising 0→1
across the fade-in, falling 1→0 across the fade-out), using the same time-to-x mapping as
everything else (`G12`), with the fade regions lightly shaded.

This is the deliberate resolution of `A8`'s warning that processing "must not be applied
on the display path or the waveform will lie about the output": the waveform shows source
amplitude, the envelope shows applied gain, and together they do not mislead.

### Interaction with existing behaviour

| | |
| --- | --- |
| Trim handles | A fade is anchored to its boundary, so it moves with the handle. Dragging `trimStart` right carries the fade-in along. |
| Playhead / seeking | Unaffected — fades do not change the time axis. |
| Loop | Unaffected (`G17`); the loop repeats the faded selection. |
| Reset | Now also clears both fades (`G30` amended) — Reset means "back to default". |
| New file | Fades reset to 0 with the rest of the document. |

## The decision this spec leaves open: can you hear it?

This is the one genuine fork, and it should be decided rather than defaulted.

| | Phase 1 — export only | Phase 2 — audible preview |
| --- | --- | --- |
| What the user gets | Correct output and a visible envelope, but **the fade is silent during audition** | Fade is heard while scrubbing and looping |
| Cost | Small: exporter read loop + envelope drawing | Moderate: `AudioEngineController` scheduling must interleave buffers with segments |
| Risk | Low — playback architecture untouched | Bounded by leaving the no-fade path exactly as it is |

**Phase 1 alone means a deaf workflow**: export, listen, adjust, re-export. For a
trimming tool whose purpose is auditioning before committing, that is a real gap.

Recommendation: **do both**, but land them as separate changes, because Phase 1 is
independently useful and testable while Phase 2 is the only part that can regress
playback.

Phase 2 mechanism, for the record: pre-render only the faded head and tail into PCM
buffers and schedule `[faded head][middle segment][faded tail]`, topping the queue up as
the existing loop already does. Memory is proportional to the *fade length*, not the
selection, so it stays bounded on a three-minute file. When both fades are 0, use the
existing pure-segment path untouched (`G46` guarantees the outputs agree).

## Guarantee edits

**Amend `G35`** — currently "Exported samples are identical to the source over the same
range":

> Exported samples are identical to the source over the same range, **multiplied by the
> fade envelope, which is 1 outside the fade regions**. With both fades at 0 ms the
> output is bit-identical to a no-fade export.

**Amend `G30`** — Reset restores the selection to the whole file **and clears both
fades**.

**Replace `A8`** — from "No audio processing at all" to:

> **Exactly one kind of processing: linear fades at the selection boundaries.** Anything
> else (gain, normalisation, EQ) still belongs in the exporter's read loop and must still
> not be applied on the display path.

**Preserve** `G24` (still one contiguous selection), `G31` (still non-destructive —
the fade is a property, nothing is written until export), `G33` (frame resolution still
in one place), `G34` (format unchanged), `G36`–`G40`, `G12`, `G26`–`G29`, and `A1`
(fades live *inside* the single selection, so the structural constraint is untouched).

## New guarantees

| | |
| --- | --- |
| **G41** | A fade multiplies every channel by the same linear gain ramp defined above: fade-in rises 0→1 across `[trimStart, trimStart + fadeIn]`, fade-out falls 1→0 across `[trimEnd − fadeOut, trimEnd]`. Both endpoints are inclusive. |
| **G42** | Fades never overlap; each is clamped to at most half the selection. |
| **G43** | Fade durations are re-clamped when the selection changes or a new file loads, so the displayed value always equals the applied value. |
| **G44** | The waveform panel draws the fade envelope using the same time-to-x mapping as the waveform, handles and playhead. |
| **G45** | Samples outside the fade regions are unmodified. |
| **G46** | With both fades at 0 ms, exported output is bit-identical to an export of the same selection with no fades. |

## Acceptance criteria

`tools/selftest.sh` — extend with:

1. **Envelope shape.** Export a fixture with a known fade; at sampled offsets the gain
   matches the analytic table (first sample exactly 0, monotonic rise, exactly 1 at the
   end of the fade-in).
2. **Fade-out endpoint.** The final exported sample is exactly 0.
3. **Untouched elsewhere.** Samples outside the fade regions are bit-identical to a
   no-fade export (this is `G45`, and it is the check that catches an off-by-one in the
   frame maths).
4. **No-op equivalence.** Both fades 0 ms produces output bit-identical to the current
   no-fade export (`G46`). This is the regression guard that protects every existing
   guarantee.
5. **Clamping.** A requested fade longer than half the selection yields exactly
   `floor(L/2)` (`G42`), including when both fades together would exceed `L`.
6. **Single-frame fade.** `fadeInFrames == 1` silences exactly the first sample and
   nothing else.

`tools/uitest.sh` — extend with:

7. **Envelope rendered.** Sampling pixels along the fade region finds the envelope line
   rising/falling as expected, and its endpoints align with the trim handles, proving
   `G44` shares the `G12` mapping.

Per AGENTS.md, each new check must be shown to fail against the pre-change code before
it is trusted.

## Risks

- **The envelope must not be mistaken for the waveform.** Contrast between the envelope
  line and the waveform is a legibility requirement, not a nicety.
- **Phase 2 touches playback scheduling**, the most subtle code in the project. Mitigated
  by leaving the no-fade path byte-for-byte as it is, with `G46` holding it in place.
- **Silent gain changes.** A fade that is applied but not obvious is a trap; hence the
  envelope is part of the feature, not a follow-up.

## Out of scope

- Equal-power, logarithmic or dB-linear curves (linear amplitude only).
- Crossfades between two regions — that needs `A1` to change.
- Fades spanning the whole file rather than the selection.
- Per-channel or per-region fades, automation curves, multiple fade points.
- Gain, normalisation, EQ, compression.
