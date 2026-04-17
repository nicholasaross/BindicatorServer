"""HTTP server exposing bin collection data to ESP32 clients."""

import logging
import os
from contextlib import asynccontextmanager

from apscheduler.schedulers.background import BackgroundScheduler
from fastapi import FastAPI
from fastapi.responses import JSONResponse

from bindicator import get_collections

logger = logging.getLogger("bindicator")

UPRN = os.environ.get("UPRN", "200001920678")
REFRESH_HOURS = int(os.environ.get("REFRESH_HOURS", "12"))

_cache: dict = {"data": None}


def _refresh_collections() -> None:
    logger.info("Scraping bin collection data...")
    try:
        _cache["data"] = get_collections(UPRN)
        logger.info("Scrape complete — %d collection dates cached", len(_cache["data"]))
    except Exception:
        logger.exception("Scrape failed")


scheduler = BackgroundScheduler()
scheduler.add_job(_refresh_collections, "interval", hours=REFRESH_HOURS)


@asynccontextmanager
async def lifespan(app: FastAPI):
    _refresh_collections()  # warm the cache on startup
    scheduler.start()
    yield
    scheduler.shutdown()


app = FastAPI(title="Bindicator API", lifespan=lifespan)


@app.get("/collections")
def collections():
    """Return all upcoming bin collections."""
    if _cache["data"] is None:
        return JSONResponse({}, status_code=503)
    return _cache["data"]


@app.get("/next")
def next_collection():
    """Return the next upcoming collection — optimised for ESP32 parsing.

    Response:
        {"date": "2025-04-07", "bins": ["Rubbish", "Recycling"]}
    """
    if not _cache["data"]:
        return JSONResponse({"date": None, "bins": []}, status_code=503)
    earliest = min(_cache["data"].keys())
    return {"date": earliest, "bins": _cache["data"][earliest]}


@app.post("/refresh")
def refresh():
    """Force-refresh the cached collection data."""
    _refresh_collections()
    return {"status": "ok", "collections": len(_cache["data"] or {})}


@app.get("/health")
def health():
    """Health-check endpoint."""
    return {"status": "ok", "cached": _cache["data"] is not None}
