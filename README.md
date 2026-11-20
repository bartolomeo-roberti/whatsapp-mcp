# whatsapp-mcp

A Cerase image connector for the third-party
[lharries/whatsapp-mcp](https://github.com/lharries/whatsapp-mcp). The upstream
project provides a Go bridge that keeps a WhatsApp Web session and a SQLite
message history, and a Python MCP server that exposes that history and the
send/download API as tools.

This repository does not vendor the upstream source. The Dockerfile fetches the
pinned commit, applies the patches in `patches/`, builds the bridge, and installs
the Python server in a separate venv. It adds the runner gate, the liveness
probe and the stdio-to-HTTP bridge that Cerase expects from an `image`
connector.

This is a community package, not endorsed by or affiliated with WhatsApp.

## Upstream

The packaged project is
[lharries/whatsapp-mcp](https://github.com/lharries/whatsapp-mcp), pinned at
commit `7d6a06dcdce1f01dfb24f60e1030d5efba9f3b88` and licensed under the MIT
License. The licence text is in [LICENSE](LICENSE), and [NOTICE](NOTICE)
records the attribution.

The patches are small and reviewable:

- `patches/0001-bump-whatsmeow.patch` moves `go.mau.fi/whatsmeow` from the
  March 2025 pin to `v0.0.0-20261116172437-19d61352436f`, with the `go.mod` and
  `go.sum` changes and the small context-argument updates the newer API needs.
- `patches/0002-login-mode.patch` adds the `--login` mode described below.
- `patches/0003-rest-loopback.patch` binds the REST server to `127.0.0.1:8080`
  instead of every interface.

The pinned whatsmeow build was checked against `web.whatsapp.com`: it reaches
the point of printing a QR code.

## Signing in

Each person links their own WhatsApp number. Cerase runs the image once with
`--login` on the person's state volume:

```sh
docker run --rm -it -v whatsapp-state:/home/pwuser/.whatsapp-mcp \
    ghcr.io/bartolomeo-roberti/whatsapp-mcp --login
```

The run prints the WhatsApp QR code as text on stdout. Open WhatsApp on the
phone, go to **Linked devices**, and scan it. A fresh QR is printed when the
previous one expires. The run exits 0 as soon as the phone has linked the device
and the session has been written to the state volume. If the volume already
holds a linked session, it exits 0 at once. If the QR is not scanned within 15
minutes, or pairing fails, it prints a final line on stderr and exits non-zero.
The login run serves no port.

Without arguments the image is the MCP runner. It refuses to start when there is
no linked session; start the `--login` run first.

## State

The state volume is mounted at `/home/pwuser/.whatsapp-mcp` and holds:

- `store/whatsapp.db` — the WhatsApp device session created by the QR login.
- `store/messages.db` — the message and chat history synced by the bridge.
- `store/<chat>/...` — media downloaded by the `download_media` tool.

The bridge runs with that directory as its working directory, and the Python
server reaches the same files through a symlink made at build time. Nothing else
is written at run time: the root filesystem is read-only and `/tmp` is a tmpfs.

## Tools

The upstream Python server exposes twelve tools. Eight only read the local
message database and are marked `read_only` in `cerase.json`:

| Tool | Access |
| --- | --- |
| `search_contacts` | read-only |
| `list_messages` | read-only |
| `list_chats` | read-only |
| `get_chat` | read-only |
| `get_direct_chat_by_contact` | read-only |
| `get_contact_chats` | read-only |
| `get_last_interaction` | read-only |
| `get_message_context` | read-only |
| `send_message` | sends a message |
| `send_file` | sends a file |
| `send_audio_message` | sends an audio message |
| `download_media` | writes a media file to the state volume |

`send_message`, `send_file`, `send_audio_message` and `download_media` are not
marked read-only because they send through WhatsApp or write a file. ffmpeg is
not installed, so `send_audio_message` can send an existing `.ogg` file but
cannot convert other formats; `send_file` still sends the file as a document.

## Risk

Automating a personal WhatsApp account is outside WhatsApp's terms and can get
the number blocked. Use a number you can afford to lose. The connector keeps the
session on the person's state volume and does not share it between people.

## Image

The publish workflow pushes `ghcr.io/bartolomeo-roberti/whatsapp-mcp` with the
tags `main` and `sha-<short>`. The catalogue entry currently carries the
placeholder digest
`ghcr.io/bartolomeo-roberti/whatsapp-mcp@sha256:f8c80fcc66db74b530a87ba7cc28a54ddc9bb106455a0b6ebd31e81f6111418e`;
after the first publish, copy the real digest from the workflow summary into
`cerase.json`.

The manifest lists the hosts the runner may reach: `whatsapp.com`,
`*.whatsapp.com` and `*.whatsapp.net`. The bridge listens on `127.0.0.1:8080`,
the MCP proxy on `127.0.0.1:3001`, and the gate exposes `:3000` to the gateway.

## Files copied from Cerase

`scripts/runner-gate.py` and `scripts/healthcheck.py` are verbatim copies from
`cerase-core/agent-runtime/mcp-runner/docker/`. They must be refreshed together
when the originals change; do not edit them here.

## Build and test

```sh
docker build -t whatsapp-mcp .
bash tests/check-image.sh whatsapp-mcp
```

The check runs the image under the console's flags (read-only root, 512 MB,
dropped capabilities) and asserts that `--login` prints a text QR and stays up,
that the runner refuses an empty volume with the "not linked" line and no QR,
that the Python server lists the twelve tools, that the read-only set in
`cerase.json` is a subset of them, and that nothing runs as root. It cannot
link a real WhatsApp account.
