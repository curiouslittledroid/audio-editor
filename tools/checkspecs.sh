#!/bin/bash
#
# Validates the specs in docs/specs/ against the baseline contract.
#
#   ./tools/checkspecs.sh
#
# A change spec is only useful if its citations are real. This checks that every
# G/A number a spec refers to actually exists in docs/specs/SPEC.md (or is declared
# as a new guarantee by that spec), that its links resolve, and that it uses the
# impact header SPEC.md prescribes.
#
set -uo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

exec python3 - "$PROJECT_ROOT" <<'PY'
import re, sys, pathlib

root = pathlib.Path(sys.argv[1])
specs_dir = root / "docs" / "specs"
baseline_path = specs_dir / "SPEC.md"

if not baseline_path.exists():
    print(f"error: no baseline at {baseline_path}", file=sys.stderr)
    sys.exit(2)

baseline = baseline_path.read_text()
base_g = {int(n) for n in re.findall(r"\*\*G(\d+)\*\*", baseline)}
base_a = {int(n) for n in re.findall(r"\*\*A(\d+)\*\*", baseline)}
max_g = max(base_g)

changes = sorted(p for p in specs_dir.glob("*.md") if p.name != "SPEC.md")
if not changes:
    print("no change specs to check")
    sys.exit(0)

problems = 0

def fail(spec, message):
    global problems
    problems += 1
    print(f"  FAIL  {message}")

print(f"baseline: {baseline_path.relative_to(root)}  (G1–G{max_g}, "
      f"A1–A{max(base_a)}),  {len(changes)} change spec(s)\n")

for spec in changes:
    text = spec.read_text()
    name = spec.relative_to(root)
    print(f"{name}")

    # 1. The impact header SPEC.md prescribes.
    missing = [k for k in ("Changes:", "Preserves:", "Adds:", "Removes:", "New checks:")
               if k not in text]
    if missing:
        fail(spec, f"impact header incomplete, missing: {', '.join(missing)}")
    else:
        print("  ok    impact header present")

    # 2. Anything declared as a new guarantee must be numbers above the baseline,
    #    and must actually be defined in this spec.
    declared = set()
    for n in re.findall(r"\*\*G(\d+)\*\*", text):
        if int(n) > max_g:
            declared.add(int(n))
    collisions = declared & base_g
    if collisions:
        fail(spec, f"declares guarantee(s) already in the baseline: {sorted(collisions)}")
    elif declared:
        print(f"  ok    adds {len(declared)} new guarantee(s): "
              f"G{min(declared)}–G{max(declared)}")
    else:
        print("  ok    adds no new guarantees")

    # 3. Every G/A reference must be real: in the baseline, or added by this spec.
    cited_g = {int(n) for n in re.findall(r"\bG(\d+)\b", text)}
    cited_a = {int(n) for n in re.findall(r"\bA(\d+)\b", text)}
    bogus_g = sorted(cited_g - base_g - declared)
    bogus_a = sorted(cited_a - base_a)
    if bogus_g:
        fail(spec, f"cites non-existent guarantee(s): {['G'+str(n) for n in bogus_g]}")
    else:
        print(f"  ok    {len(cited_g)} guarantee citation(s) all resolve")
    if bogus_a:
        fail(spec, f"cites non-existent assumption(s): {['A'+str(n) for n in bogus_a]}")
    else:
        print(f"  ok    {len(cited_a)} assumption citation(s) all resolve")

    # 4. Relative links must resolve from the spec's own directory.
    broken = [t for t in re.findall(r"\]\(([^)#]+)\)", text)
              if not (spec.parent / t).resolve().exists()]
    if broken:
        fail(spec, f"broken link(s): {broken}")
    else:
        print("  ok    links resolve")

    # 5. Renumbering the baseline would silently invalidate every citation.
    nums = sorted(map(int, re.findall(r"\*\*G(\d+)\*\*", baseline)))
    if nums != list(range(1, len(nums) + 1)):
        fail(spec, "baseline guarantee numbering is not contiguous 1..N — citations are unstable")
    print()

print(f"{'FAILED' if problems else 'PASSED'} — {problems} problem(s)")
sys.exit(1 if problems else 0)
PY