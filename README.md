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

## API Endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/next` | Next collection date and bin types (ESP32-optimised) |
| GET | `/collections` | All upcoming collection dates |
| POST | `/refresh` | Force an immediate re-scrape |
| GET | `/health` | Health check |

### Example `/next` response

```json
{"date": "2025-04-07", "bins": ["Rubbish", "Recycling"]}
```
