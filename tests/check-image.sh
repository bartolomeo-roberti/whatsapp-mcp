#!/bin/bash
set -euo pipefail

image=${1:?usage: check-image.sh <image>}

login_container=wa-check-login
runner_container=wa-check-runner
volume=wa-check-vol-$$
runner_volume=wa-check-runner-vol-$$
out=$(mktemp)
err=$(mktemp)

cleanup() {
    docker rm -f "$login_container" "$runner_container" >/dev/null 2>&1 || true
    docker volume rm -f "$volume" "$runner_volume" >/dev/null 2>&1 || true
    rm -f "$out" "$err"
}
trap cleanup EXIT

# A previous interrupted run must not leave the fixed container names or the
# per-PID volumes behind.
docker rm -f "$login_container" "$runner_container" >/dev/null 2>&1 || true
docker volume rm -f "$volume" "$runner_volume" >/dev/null 2>&1 || true

fail() {
    printf 'check-image: %s\n' "$1" >&2
    exit 1
}

# The flags the console runs a connector under. The memory ceiling is the one
# cerase.json declares.
flags=(
    --read-only
    --tmpfs /tmp:rw,nosuid,nodev,size=256m
    --cap-drop ALL
    --security-opt no-new-privileges:true
    --memory 512m
)

# (d) Nothing runs as root at run time.
configured_user=$(docker inspect -f '{{.Config.User}}' "$image") ||
    fail "cannot inspect $image"
case $configured_user in
    pwuser | 1000) ;;
    *) fail "the image user is '$configured_user', not pwuser/1000" ;;
esac
runtime_uid=$(docker run --rm "${flags[@]}" --entrypoint id "$image" -u) ||
    fail "cannot read the runtime uid"
[[ $runtime_uid == 1000 ]] ||
    fail "the image runs as uid $runtime_uid, not 1000"

# The root filesystem is read-only, so anything outside the state volume and
# /tmp fails. This also proves the flag is really in force.
if docker run --rm "${flags[@]}" --entrypoint sh "$image" -c 'touch /cerase-check' >/dev/null 2>&1; then
    fail "the root filesystem is writable"
fi

# (a) --login on an empty volume prints a text QR and stays up.
docker volume create "$volume" >/dev/null || fail "cannot create the login volume"
docker run -d --name "$login_container" "${flags[@]}" \
    -v "$volume:/home/pwuser/.whatsapp-mcp" "$image" --login >/dev/null ||
    fail "cannot start the login run"

qr=0
for _ in $(seq 1 60); do
    if docker logs "$login_container" >"$out" 2>"$err"; then
        if grep -qF 'Scan this QR code' "$out" && grep -q '▀\|▄\|█' "$out"; then
            qr=1
            break
        fi
    fi
    if ! docker inspect -f '{{.State.Running}}' "$login_container" 2>/dev/null | grep -qx true; then
        docker logs "$login_container" >&2 || true
        fail "the login run exited before printing a QR"
    fi
    sleep 1
done
if [[ $qr -ne 1 ]]; then
    docker logs "$login_container" >&2 || true
    fail "the login run did not print a text QR within 60 s"
fi

sleep 20
running=$(docker inspect -f '{{.State.Running}}' "$login_container" 2>/dev/null) ||
    fail "cannot inspect the login run"
if [[ $running != true ]]; then
    docker logs "$login_container" >&2 || true
    fail "the login run stopped 20 s after the QR"
fi
docker rm -f "$login_container" >/dev/null 2>&1 || true

# (b) The runner on an empty volume refuses, with the not-linked line on
# stderr and no QR.
docker volume create "$runner_volume" >/dev/null || fail "cannot create the runner volume"
set +e
timeout 30 docker run --name "$runner_container" "${flags[@]}" \
    -v "$runner_volume:/home/pwuser/.whatsapp-mcp" "$image" >"$out" 2>"$err"
status=$?
set -e
if [[ $status -eq 0 ]]; then
    fail "the runner exited 0 with no linked session"
fi
if [[ $status -eq 124 ]]; then
    fail "the runner did not exit within 30 s with no linked session"
fi
if ! grep -q 'not linked' "$err"; then
    printf '%s\n' '--- runner stderr ---' >&2
    sed -n '1,40p' "$err" >&2 || true
    fail "the runner did not print the not-linked line on stderr"
fi
if grep -q '▀\|▄\|█' "$out" "$err"; then
    fail "the runner printed a QR with no linked session"
fi
docker rm -f "$runner_container" >/dev/null 2>&1 || true

# (c) The Python server on its own lists exactly the twelve tools. The client
# comes from the mcp package in /opt/bridge, which is also what mcp-proxy uses.
names_json=$(docker run --rm -i "${flags[@]}" \
    --entrypoint /opt/bridge/bin/python "$image" - <<'PY'
import asyncio
import json

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main() -> None:
    params = StdioServerParameters(
        command="/opt/whatsapp-mcp/.venv/bin/python",
        args=["/opt/whatsapp-mcp/whatsapp-mcp-server/main.py"],
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            print("TOOLS_JSON=" + json.dumps(sorted(tool.name for tool in tools.tools)))


asyncio.run(main())
PY
) || fail "cannot list the Python server's tools"
names_json=$(sed -n 's/^TOOLS_JSON=//p' <<<"$names_json") ||
    fail "cannot read the tool list"
[[ -n $names_json ]] || fail "the Python server returned no tool list"

# (e) cerase.json parses, and its read-only names are tools of (c).
python3 - "$names_json" <<'PY' || fail "cerase.json does not match the server's tools"
import json
import sys

names = json.loads(sys.argv[1])
expected = {
    "search_contacts",
    "list_messages",
    "list_chats",
    "get_chat",
    "get_direct_chat_by_contact",
    "get_contact_chats",
    "get_last_interaction",
    "get_message_context",
    "send_message",
    "send_file",
    "send_audio_message",
    "download_media",
}
if len(names) != 12 or set(names) != expected:
    print(f"the server lists {names}, not the twelve upstream tools", file=sys.stderr)
    sys.exit(1)

with open("cerase.json", encoding="utf-8") as stream:
    manifest = json.load(stream)
read_only = set(manifest["tool_side_effects"]["read_only"])
missing = read_only - set(names)
if missing:
    print(f"read_only names are not tools: {sorted(missing)}", file=sys.stderr)
    sys.exit(1)
print(f"tools ok: {len(names)} listed, {len(read_only)} read-only")
PY

printf 'check-image: ok\n'
