#!/usr/bin/env bash
# Writes ~/.config/veil/config.json from keys typed at the prompt.
# Input is hidden and the keys are never echoed, logged or committed.
set -euo pipefail

DEST="${HOME}/.config/veil/config.json"
mkdir -p "$(dirname "$DEST")"

read -rsp "Deepgram API key: " DEEPGRAM; echo
read -rsp "Anthropic API key: " ANTHROPIC; echo

VEIL_DG="$DEEPGRAM" VEIL_AN="$ANTHROPIC" python3 - "$DEST" <<'PY'
import json, os, sys
dest = sys.argv[1]
config = {
    "deepgram_api_key": os.environ["VEIL_DG"],
    "anthropic_api_key": os.environ["VEIL_AN"],
    "model": "claude-opus-5",
    "stt_model": "nova-3",
    "language": "en",
    "persona": "You are assisting the user during a live conversation.",
}
with open(dest, "w") as f:
    json.dump(config, f, indent=2)
os.chmod(dest, 0o600)
PY

echo "wrote $DEST (mode 600)"
echo "deepgram key length: ${#DEEPGRAM}, anthropic key length: ${#ANTHROPIC}"
