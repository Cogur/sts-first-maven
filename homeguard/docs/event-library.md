# Event library

All events (snapshots, synced or imported monitor files, and audit records such as door unlocks) are `SecurityEvent`s in a single local `EventStore`. Media lives in the app sandbox, and metadata lives in one JSON index that is written atomically. Device file names are the only source of type and time for imported media.

**Use this document when:** you add an event type, record something for the audit log, change sync/import, touch the Events timeline or detail page, or parse device file names.

**Not covered:** the unlock flow that writes audit records → [door-unlock.md](door-unlock.md). HTTP to the monitor → [device-protocols.md](device-protocols.md).

## Definitions

| Term | Meaning here |
|---|---|
| Media event | Has `mediaPath` (absolute sandbox path) and `mediaKind` image/video. Created by `addMedia`. |
| Record | No media (`addRecord`), e.g. unlock audit entries. |
| `note` | Free text. **For imported files it holds the original file name**, which is used as the dedup key (`hasSource`). |
| Storage layout | `<ApplicationSupport>/events/index.json` + `events/media/<uuid>.<ext>` |
| `maxEvents` | 2000. Inserting beyond it evicts the oldest events **and deletes their media**. |

## Flow

- Load: `main.dart` → `events.load()`. Bad JSON → logged, start empty (media files remain on disk).
- Insert (`_insert`): prepend, sort newest-first, evict over cap, `_persist()` (write `index.json.tmp` then rename), notify.
- Snapshot: `captureSnapshot` → `addMedia(type: manualSnapshot)`.
- Monitor sync (`lib/core/services/monitor_sync_service.dart`): `require(monitor)` → GET `eventIndexPath` → `parseIndex` (JSON array of paths or `{path|url}`, or HTML `href` links to media extensions) → newest first, skip known names, stop at 50 downloads, **skip links to another host** → `importFiles`.
- SD-card import (`events_page.dart`): file picker (media) → `importFiles`.
- `importFiles`: ignore non-media extensions and known names; `EventType.fromHint(name)` and `SecurityEvent.timestampFromName(name)` (e.g. `20261015_083012_FACE.jpg`, `call_2026-01-15-08-30-12.jpg`).
- UI: `EventsPage` filters by type chips; `EventDetailPage` shows images (zoom) or plays clips with a `file`-only player; the Access tab shows door/RFID/call events plus failed unlocks.

## Invariants and pitfalls

- Add a new `EventType` value with a `label`. `fromJson` maps unknown names to `other`, so old indexes stay readable. Don't rename existing enum values; they are the stored keys.
- `fromHint` checks keywords in order (face → call/ring/bell → motion → card/rfid → unlock/open → manual/snap). A new keyword can steal matches from a later type.
- Timestamps are stored as UTC ISO strings and loaded as local time.
- Don't write media outside `_eventsDir()`. Media must stay out of shared storage and gallery apps.
- `wipe()` deletes the whole `events/` folder. It is part of erase-all.

## Related

- Pair: [door-unlock.md](door-unlock.md)
- Tests: `test/events_test.dart` (name inference, index parsing, persistence, dedup, delete, corrupt index).
