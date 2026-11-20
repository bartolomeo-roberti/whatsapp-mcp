#!/bin/bash
set -euo pipefail

# Tini is PID 1. It reaps zombies and forwards SIGTERM to this supervisor, which
# then stops both the WhatsApp bridge and the MCP chain. Re-exec once so the
# supervisor is never PID 1 itself.
if [[ ${CERASE_TINI_CHILD:-} != 1 ]]; then
    export CERASE_TINI_CHILD=1
    exec tini -e 143 -- "$0" "$@"
fi

state=/home/pwuser/.whatsapp-mcp
bridge=/opt/whatsapp-mcp/whatsapp-bridge/whatsapp-bridge
mkdir -p "$state/store"

# Both modes run the bridge from the state directory so its relative store/ is
# the mounted volume; the Python server reaches the same directory through the
# symlink made at build time.
cd "$state"

# `--login` prints the QR the upstream bridge prints and exits 0 as soon as the
# phone has linked the device and the session is stored. It serves no port.
if [[ ${1-} == --login ]]; then
    exec "$bridge" --login
fi

# The runner. Start the bridge; it refuses a missing session with its own clear
# line on stderr.
"$bridge" &
bridge_pid=$!

# Wait for the REST server on loopback before exposing the MCP chain. A bridge
# with no stored session exits at once with its own clear line on stderr.
ready=0
for _ in $(seq 1 300); do
    if ! kill -0 "$bridge_pid" 2>/dev/null; then
        wait "$bridge_pid" || true
        echo "whatsapp-mcp: the bridge exited before its REST server was ready" >&2
        exit 1
    fi
    if (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null; then
        exec 3>&- 2>/dev/null || true
        ready=1
        break
    fi
    sleep 0.2
done

if [[ $ready -ne 1 ]]; then
    echo "whatsapp-mcp: the bridge did not answer on 127.0.0.1:8080" >&2
    kill -TERM "$bridge_pid" 2>/dev/null || true
    wait "$bridge_pid" 2>/dev/null || true
    exit 1
fi

python3 /opt/cerase/runner-gate.py -- /opt/bridge/bin/mcp-proxy \
    --port 3001 --host 127.0.0.1 --pass-environment -- \
    /opt/whatsapp-mcp/.venv/bin/python /opt/whatsapp-mcp/whatsapp-mcp-server/main.py &
gate_pid=$!

stop() {
    trap - TERM INT
    kill -TERM "$gate_pid" "$bridge_pid" 2>/dev/null || true
    wait "$gate_pid" 2>/dev/null || true
    wait "$bridge_pid" 2>/dev/null || true
}
trap stop TERM INT

# If either process dies the runner is unusable: stop the other and exit.
set +e
wait -n "$bridge_pid" "$gate_pid"
status=$?
set -e
if ! kill -0 "$bridge_pid" 2>/dev/null; then
    echo "whatsapp-mcp: the WhatsApp bridge exited; stopping the runner" >&2
fi
stop
exit "$status"
