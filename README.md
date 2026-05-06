# Bindicator

Server that scrapes bin collection dates from the Reigate & Banstead council website and exposes them over HTTP for an ESP32 client.

## Deployment (Synology NAS)

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

**`503 Service Unavailable`** — cache not yet populated:

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
| `status` | string | `"ok"` on success |
| `collections` | integer | Number of collection dates now cached |

### `GET /health`

Lightweight liveness probe. Does not hit the council site.

**`200 OK`**

```json
{"status": "ok", "cached": true}
```

| Field | Type | Description |
|---|---|---|
| `status` | string | Always `"ok"` while the server is running |
| `cached` | boolean | `true` once the cache has been populated at least once |
