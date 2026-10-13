#!/bin/bash
#
# Sends a PNG plus a question to a vision model and prints the answer.
# Used to verify rendered UI snapshots without Screen Recording permission.
#
#   ./tools/inspect.sh shot.png "Describe the layout and any visual problems."
#
set -euo pipefail

IMAGE="${1:?usage: inspect.sh <image.png> [prompt]}"
PROMPT="${2:-Describe this UI screenshot in detail. Report any visual problems: clipping, overlap, misalignment, cut-off or blank areas.}"
MODEL="${VISION_MODEL:-google/gemini-2.5-flash}"

KEY="$(python3 -c "import json;print(json.load(open('$HOME/.pi/agent/auth.json'))['openrouter']['key'])")"

python3 - "$IMAGE" "$PROMPT" "$MODEL" "$KEY" <<'PY'
import base64, json, sys, urllib.request, mimetypes

image_path, prompt, model, key = sys.argv[1:5]
mime = mimetypes.guess_type(image_path)[0] or "image/png"
with open(image_path, "rb") as fh:
    b64 = base64.b64encode(fh.read()).decode()

payload = {
    "model": model,
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}},
        ],
    }],
    "temperature": 0,
}

req = urllib.request.Request(
    "https://openrouter.ai/api/v1/chat/completions",
    data=json.dumps(payload).encode(),
    headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
)

try:
    with urllib.request.urlopen(req, timeout=180) as resp:
        data = json.load(resp)
except urllib.error.HTTPError as err:
    print(f"HTTP {err.code}: {err.read().decode()[:800]}", file=sys.stderr)
    sys.exit(1)

choice = data["choices"][0]["message"]["content"]
print(choice if isinstance(choice, str) else json.dumps(choice, indent=2))
PY
