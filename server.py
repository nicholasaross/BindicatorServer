"""HTTP server exposing bin collection data to ESP32 clients."""

import json
import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from apscheduler.jobstores.base import JobLookupError
from apscheduler.schedulers.background import BackgroundScheduler
from fastapi import FastAPI
from fastapi.responses import JSONResponse

from bindicator import get_collections

logger = logging.getLogger("bindicator")

UPRN = os.environ.get("UPRN", "200001920678")
REFRESH_HOURS = int(os.environ.get("REFRESH_HOURS", "12"))
TZ = ZoneInfo(os.environ.get("TZ", "Europe/London"))

# Last good scrape is persisted here so the cache survives a host/container
# restart and we never serve null while the first post-restart scrape runs.
CACHE_FILE = Path(os.environ.get("CACHE_FILE", "/data/collections.json"))

# When a scrape fails and the cache is still empty (e.g. the network wasn't
# ready right after a host reboot), retry this often (minutes) instead of
# waiting REFRESH_HOURS for the next scheduled refresh.
RETRY_MINUTES = int(os.environ.get("RETRY_MINUTES", "10"))

# Bins are collected in the morning; past noon, treat today as done so
# /next rolls over to the following collection.
ROLLOVER_HOUR = 12

_BOOTSTRAP_JOB_ID = "bootstrap-retry"

_cache: dict = {"data": None}


def _load_cache() -> dict | None:
    """Return the last persisted collections, or None if unavailable."""
    try:
        data = json.loads(CACHE_FILE.read_text())
    except FileNotFoundError:
        return None
    except Exception:
        logger.exception("Failed to read cache file %s", CACHE_FILE)
        return None
    logger.info("Loaded %d cached collection dates from %s", len(data), CACHE_FILE)
    return data


def _save_cache(data: dict) -> None:
    """Persist collections so they survive a restart (best effort)."""
    try:
        CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        CACHE_FILE.write_text(json.dumps(data))
    except Exception:
        logger.exception("Failed to write cache file %s", CACHE_FILE)


def _refresh_collections() -> bool:
    """Scrape and cache collection data. Returns True on success."""
    logger.info("Scraping bin collection data...")
    try:
        data = get_collections(UPRN)
    except Exception:
        logger.exception("Scrape failed")
        return False
    _cache["data"] = data
    _save_cache(data)
    logger.info("Scrape complete — %d collection dates cached", len(data))
    return True


scheduler = BackgroundScheduler()


def _bootstrap_retry() -> None:
    """Fast-retry the scrape until the cache is populated, then stop.

    Scheduled for every restart but self-cancels: on a healthy start the
    immediate refresh has already populated the cache, so the first tick just
    removes the job; on a failed start it keeps retrying every RETRY_MINUTES.
    """
    if _cache["data"] or _refresh_collections():
        try:
            scheduler.remove_job(_BOOTSTRAP_JOB_ID)
        except JobLookupError:
            pass


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Serve the last good scrape immediately so a restart never shows null
    # while the first scrape runs in the background.
    _cache["data"] = _load_cache()
    # Regular refresh, with the first run scheduled now so the cache warms on
    # startup (not REFRESH_HOURS later). Runs in a scheduler thread, so it
    # never blocks the server from coming up.
    scheduler.add_job(
        _refresh_collections,
        "interval",
        hours=REFRESH_HOURS,
        next_run_time=datetime.now(TZ),
        id="refresh",
    )
    # Safety net for a failed startup scrape: retry soon instead of waiting
    # for the next REFRESH_HOURS interval.
    scheduler.add_job(
        _bootstrap_retry,
        "interval",
        minutes=RETRY_MINUTES,
        id=_BOOTSTRAP_JOB_ID,
    )
    scheduler.start()
    yield
    scheduler.shutdown()


app = FastAPI(title="Bindicator API", lifespan=lifespan)


@app.get("/collections")
def collections():
    """Return all upcoming bin collections."""
    if not _cache["data"]:
        return JSONResponse({}, status_code=503)
    return _cache["data"]


def _effective_today() -> str:
    """ISO date treated as 'today' for /next purposes.

    Past the rollover hour, today is considered done and tomorrow's date
    is returned, so today's collection drops out of the upcoming list.
    """
    now = datetime.now(TZ)
    if now.hour >= ROLLOVER_HOUR:
        return (now.date() + timedelta(days=1)).isoformat()
    return now.date().isoformat()


@app.get("/next")
def next_collection():
    """Return the next upcoming collection — optimised for ESP32 parsing.

    Response:
        {"date": "2025-04-07", "bins": ["Rubbish", "Recycling"]}
    """
    if not _cache["data"]:
        return JSONResponse({"date": None, "bins": []}, status_code=503)
    cutoff = _effective_today()
    upcoming = [d for d in _cache["data"] if d >= cutoff]
    if not upcoming:
        return JSONResponse({"date": None, "bins": []}, status_code=503)
    earliest = min(upcoming)
    return {"date": earliest, "bins": _cache["data"][earliest]}


@app.post("/refresh")
def refresh():
    """Force-refresh the cached collection data."""
    ok = _refresh_collections()
    if not _cache["data"]:
        # Scrape failed and nothing cached to fall back on.
        return JSONResponse({"status": "error", "collections": 0}, status_code=503)
    return {
        "status": "ok" if ok else "stale",
        "collections": len(_cache["data"]),
    }


@app.get("/health")
def health():
    """Health-check endpoint."""
    return {"status": "ok", "cached": bool(_cache["data"])}
