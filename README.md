# Clem

**Your Mac remembers what you saw — then you can ask it anything.**

Clem quietly watches your screen, reads the text on-device, and turns your day into searchable memory. Chat with it. Map it. Stay focused. Everything stays on your machine.

## What you get

- **Ask** — “What was that error an hour ago?” Answers with citations to real moments.
- **Today** — Where your time went (apps *and* sites), plus patterns Clem noticed.
- **Discover** — A feed of your own bookmarks and saves.
- **Graph & Canvas** — See how ideas connect; think with your memories.
- **Goals** — Limits and focus targets against real screen time.
- **Private by default** — Blocklist before capture. Local LLM option. Nothing leaves unless you choose a cloud model.

## Quick start

**Needs:** Apple Silicon Mac · macOS 14+ · [Ollama](https://ollama.com) · [Supermemory Local](https://supermemory.ai/docs/self-hosting/overview)

```bash
# 1. Model
ollama pull qwen3:8b

# 2. Memory engine (leave running, or let Clem start it)
supermemory-server

# 3. Build & open
cd macos
./Scripts/make-app.sh
open /Applications/Clem.app
```

On first launch: allow **Screen Recording** and **Accessibility**. Optional: Full Disk Access for native Screen Time.

Hotkeys: **⌥Space** ask · **⌥S** save what’s on screen.

## Repo

| Folder | What’s in it |
| --- | --- |
| `macos/` | The Clem app (Swift) |
| `marketing/` | Landing page |
| `archive/` | Old prototypes — not shipped |

Your data lives in `~/Library/Application Support/Clem/`.
