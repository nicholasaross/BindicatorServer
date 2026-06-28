# Bindicator

Server that scrapes bin collection dates from the Reigate & Banstead council website and exposes them over HTTP for an ESP32 client.

## Deployment (Synology NAS)

### One-shot deploy from a Windows dev box

[`scripts/deploy-to-nas.ps1`](scripts/deploy-to-nas.ps1) builds the image locally, ships it to the NAS over SSH, and (with `-Start`) writes a compose file and brings the stack up — no manual steps in Container Manager:

```powershell
# Build, copy, load, and start the stack on the NAS:
.\scripts\deploy-to-nas.ps1 -NasHost 192.168.1.50 -NasUser admin -Start

# Re-deploy after code changes (same command; it rebuilds and restarts):
.\scripts\deploy-to-nas.ps1 -NasHost 192.168.1.50 -NasUser admin -Start
```

Useful switches: `-SkipBuild` (reuse the local image), `-SshKey` / `-SshPort` (SSH options), `-HostPort` (publish on a free port if `:8000` is taken), and `-Uprn` / `-RefreshHours` / `-TimeZone` (override the deployed config). Run `Get-Help .\scripts\deploy-to-nas.ps1 -Detailed` for the full list.

**Prerequisites:** Docker Desktop on the dev box; SSH enabled on the NAS (Control Panel → Terminal & SNMP) with an administrator account (docker runs via `sudo`). The script builds `linux/amd64` for the DS218+/Celeron and auto-detects `docker-compose` (v1) vs `docker compose` (v2) on the NAS.

The deployed compose bind-mounts `<RemoteDir>/data` → `/data`, so the scraped schedule is persisted on the NAS and survives container and host restarts.

### Manual (compose on the NAS)

Build and start the container:

```bash
docker-compose up -d --build
```

Stop it:

```bash
docker-compose down
```

Rebuild after code changes:

```bash
docker-compose up -d --build
```

> **Note:** Synology NAS uses `docker-compose` (hyphenated, v1). The newer `docker compose` (space, v2 plugin) is not available on most Synology systems.

## Configuration

Environment variables in `docker-compose.yml`:

| Variable | Default | Description |
|---|---|---|
| `UPRN` | `200001920678` | Property identifier for the council lookup |
| `REFRESH_HOURS` | `12` | How often to re-scrape (hours) |
| `TZ` | `Europe/London` | Timezone used for the `/next` rollover (see below) |
| `CACHE_FILE` | `/data/collections.json` | Where the last good scrape is persisted (volume-mounted) |
| `RETRY_MINUTES` | `10` | How often to retry after a failed scrape until the cache is populated |

## Restart robustness

The schedule cache is designed to survive restarts (e.g. a NAS reboot):

- **Persistence** — every successful scrape is written to `CACHE_FILE` on a mounted volume. On startup the server loads it immediately, so a restart serves the last known schedule right away instead of a null/empty response.
- **Immediate warm-up** — the first scrape is scheduled to run at startup (in the background, so it doesn't block the server), not `REFRESH_HOURS` later.
- **Fast retry** — if a scrape fails (common right after a host reboot, before the network is ready), the server retries every `RETRY_MINUTES` until it succeeds, rather than waiting for the next `REFRESH_HOURS` interval.
- **No null payloads** — while no schedule is available, the read endpoints return **`503`** (see below), never `200` with a null date.

## API

All responses are `application/json`. FastAPI also serves auto-generated interactive docs at `/docs` (Swagger UI) and `/redoc`.

| Method | Path | Description |
|---|---|---|
| GET | [`/next`](#get-next) | Next collection date and bin types (ESP32-optimised) |
| GET | [`/collections`](#get-collections) | All upcoming collection dates |
| POST | [`/refresh`](#post-refresh) | Force an immediate re-scrape |
| GET | [`/health`](#get-health) | Health check |

### `GET /next`

Returns the next upcoming collection. Past **noon local time** (`ROLLOVER_HOUR` in `TZ`), today is treated as already collected and the response rolls over to the next collection. This avoids the indicator showing a stale "today" all afternoon and evening after the bins have been emptied.

**`200 OK`**

```json
{"date": "2025-04-07", "bins": ["Rubbish", "Recycling"]}
```

| Field | Type | Description |
|---|---|---|
| `date` | string | ISO date (`YYYY-MM-DD`) of the next collection |
| `bins` | string[] | Bin types collected on that date |

**`503 Service Unavailable`** — cache not yet populated, or no upcoming collections in cache:

```json
{"date": null, "bins": []}
```

### `GET /collections`

Returns every upcoming collection currently cached.

**`200 OK`** — object keyed by ISO date, values are arrays of bin-type strings:

```json
{
  "2025-04-07": ["Rubbish", "Recycling"],
  "2025-04-14": ["Garden", "Food"]
}
```

**`503 Service Unavailable`** — no schedule available (cache not yet populated):

```json
{}
```

### `POST /refresh`

Forces an immediate re-scrape of the council site. Synchronous — typically takes 30-60 seconds while headless Chrome loads the page. Use sparingly; the background scheduler already refreshes every `REFRESH_HOURS` (default 12).

**`200 OK`**

```json
{"status": "ok", "collections": 8}
```

| Field | Type | Description |
|---|---|---|
| `status` | string | `"ok"` on a successful scrape, or `"stale"` if the scrape failed but a previously cached schedule is still being served |
| `collections` | integer | Number of collection dates now cached |

**`503 Service Unavailable`** — the scrape failed and there is no cached schedule to fall back on:

```json
{"status": "error", "collections": 0}
```

### `GET /health`

Lightweight liveness probe. Does not hit the council site.

**`200 OK`**

```json
{"status": "ok", "cached": true}
```

| Field | Type | Description |
|---|---|---|
| `status` | string | Always `"ok"` while the server is running |
| `cached` | boolean | `true` while a schedule is cached (loaded from disk or freshly scraped) |
