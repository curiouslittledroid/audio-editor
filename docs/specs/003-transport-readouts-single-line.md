# 003 — Transport readouts stay on one line

**Baseline:** [`SPEC.md`](SPEC.md) — written against `G1`–`G47`.
**Status:** implemented.
**Date:** 2026-10-15

```
Changes:    none — no guarantee covers transport-bar layout
Preserves:  G11, G12, G15, G24, G26–G28, G30, G41, G44
Adds:       none
Removes:    none
New checks: uitest gains a minimum-width case and a check that the In/Out
            readouts occupy a single text line
```

## The bug

At the minimum window width the bottom bar squeezed its readouts until `0:01.000`
wrapped onto two lines, showing as `0:01` over `.000`. The In, Out, Kept and fade
values all wrapped.

Two things contributed:

1. **The playhead readout reserved 96 pt for text that needs ~64 pt.** The dead
   gap pushed the `/` total away from the time — the visible symptom — and spent
   ~32 pt the bar did not have.
2. **The readouts were compressible.** `Text` in an `HStack` that runs out of room
   wraps rather than holding its size, so the stat-box values and even the fade
   field's `ms` unit collapsed as the bar shrank.

## The fix

- The playhead readout is sized to the widest timestamp the loaded file can show
  (`0:00.000` / `10:00.000` / `1:00:00.000`) instead of a flat 96 pt, and the `/`
  total sits 4 pt after it. Fixed width still prevents jitter as digits change.
- The `IN`/`OUT`/`KEPT` values, the fade labels and the fade `ms` unit are given
  `.fixedSize(horizontal: true, vertical: false)`, so they keep their natural width
  and cannot wrap. The bar now fits at the 920 pt minimum without collapsing any
  readout.
- Transport-bar spacing is reduced from 14 pt to 10 pt to make the room.

No behaviour changes: this is layout only. The playhead is still a timestamp, the
total is still a timestamp, and every shortcut and readout is unchanged.

## The harness fix this depended on

`AUDIOEDIT_SIZE` had never worked. `SnapshotController.attach` sized
`NSApp.windows.first`, but SwiftUI keeps more than one window alive and the window
that is later captured was not that one, so every capture silently rendered at the
minimum size. The requested size is now applied to the chosen window in
`captureAndExit`, which is what makes a minimum-width test possible at all.

## Checks

`tools/uitest.sh`:

- New case `ui-7-min-width` renders at `920x480`.
- New check: the amber `IN`/`OUT` values are found in the transport bar and each
  occupies exactly one row-band of ink. A wrapped value reads as two bands and
  about half the horizontal span.

The check is confirmed to fail against the old layout:

```
FAIL  In/Out readouts are single-line (numbers do not wrap)
      — x798–852: 2 lines, x907–961: 2 lines
```

uitest 75 → 102 checks (the new check runs in every case; `ui-7` adds 21).

Anchoring matters: the check starts below the **waveform panel**, not below the
waveform ink. The amber trim handles reach lower than the loudest waveform bar, so
starting at the waveform's bottom measured the handles and reported four amber
blocks instead of the two readouts.
