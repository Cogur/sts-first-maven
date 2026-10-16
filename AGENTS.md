# Agent guide: sts-first-maven

This file is the always-on router for every AI agent (Claude Code, Cursor, Copilot, Codex…) and a map for humans. Keep it short: it points at docs, it does not repeat them.

| App | Folder | Router |
|---|---|---|
| HomeGuard: local-first Flutter security app (Techson NVR, door station, indoor monitor) | `homeguard/` | [`homeguard/AGENTS.md`](homeguard/AGENTS.md) |

Rules that apply to the whole repo:
- When a task touches an app, read that app's `AGENTS.md` first and follow its routing table.
- If a code change makes a doc wrong, fix the doc in the same change. A doc that lies is worse than no doc.
- Team knowledge goes in `<app>/docs/`. Personal agent preferences do not belong in this repo.
