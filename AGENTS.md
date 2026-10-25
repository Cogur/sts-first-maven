# Agent guide: project-cogur

This file is the always-on router for every AI agent (Claude Code, Cursor, Copilot, Codex…) and a map for humans. Keep it short: it points at docs, it does not repeat them.

Each app is developed on its own branch until it is merged here. Start a new app on a new branch from `master`.

| App | Folder | Branch | Router |
|---|---|---|---|
| HomeGuard: local-first Flutter security app (Techson NVR, door station, indoor monitor) | `homeguard/` | `claude/security-camera-mobile-app-kxp2a1` (newest code); `claude/ai-docs-knowledge-base` (agent docs) | `homeguard/AGENTS.md` (docs branch) |
| Flair Log: Flair 58 gauge reader (camera) + BOOKOO scale shot logger | `flair_log/` | `claude/flair58-brew-logger` | `flair_log/AGENTS.md` |
| Piackereső: one search across Hardverapró, Jófogás, Vinted and Facebook Marketplace; local Python server + web UI | `piackereso/` | `ccr-8d9bb3c4-tgq8da` | `piackereso/AGENTS.md` |

## Shared how-tos (every app, existing and new)

These apply to all apps, including ones created later. Follow them without being asked. The user should never have to repeat them.

| Task mentions… / when | Read |
|---|---|
| APK, Android build, install on phone, test build, CI, GitHub Actions, release page; **creating any new Flutter app** | [`docs/build-apk.md`](docs/build-apk.md) |
| Raspberry Pi, run on a Pi, home server, start on boot, systemd service, SSH install | [`docs/raspberry-pi-service.md`](docs/raspberry-pi-service.md) |

## Rules that apply to the whole repo

- When a task touches an app, read that app's `AGENTS.md` first and follow its routing table.
- If a code change makes a doc wrong, fix the doc in the same change. A doc that lies is worse than no doc.
- Team knowledge goes in `<app>/docs/`. Personal agent preferences do not belong in this repo.
- **Reusable processes go in root `docs/`, not in an app.** If what you work out would help another project (build, CI, signing, release, sandbox workarounds), write it generically in `docs/<topic>.md` and add a row to *Shared how-tos*. App docs link to it and keep only what is specific to the app. Never copy a shared doc into an app.
- **New app checklist:** add a row to the app table above (and to `master`'s copy of this file), give the app its own `AGENTS.md`, and apply every *Shared how-to* that fits (for a Flutter app, its test-APK workflow from the first push).
