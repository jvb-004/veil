#!/usr/bin/env bash
# Hands-free end-to-end test of the Linux daemon.
#
# Synthesises a spoken question into the default sink. That lands on the sink's
# monitor source, which is exactly where the daemon listens for the far end of
# a call, so the whole path gets exercised without anyone speaking:
#
#   espeak-ng -> sink -> monitor -> pw-record -> Deepgram -> trigger -> Claude -> D-Bus
#
# Usage: scripts/live-test.sh ["a question to ask"]
set -uo pipefail

QUESTION="${1:-How much does one litre of milk cost in Hungary?}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON="$ROOT/target/release/veil-daemon"
LOG="$(mktemp -t veil-live-XXXX.log)"
SIGNALS="$(mktemp -t veil-dbus-XXXX.log)"

[ -x "$DAEMON" ] || { echo "build it first: cargo build --release -p veil-daemon"; exit 1; }

echo "log:     $LOG"
echo "signals: $SIGNALS"
echo

RUST_LOG=info "$DAEMON" >"$LOG" 2>&1 &
DAEMON_PID=$!
trap 'kill $DAEMON_PID $DBUS_PID 2>/dev/null' EXIT

# Watch what the overlay would be told, without needing the overlay installed.
gdbus monitor --session --dest dev.veil.Daemon >"$SIGNALS" 2>&1 &
DBUS_PID=$!

echo "waiting for the daemon to come up..."
for _ in $(seq 1 20); do
  grep -q "far-end target" "$LOG" && break
  sleep 0.5
done
sed -n '1,12p' "$LOG"
echo

echo ">>> speaking: $QUESTION"
espeak-ng -s 145 -v en-gb "$QUESTION" 2>/dev/null
sleep 12

echo
echo "=== daemon log ==="
cat "$LOG"
echo
echo "=== D-Bus signals the overlay would have received ==="
grep -E "Answer|Sharing|Status" "$SIGNALS" | head -40 || echo "(none)"
