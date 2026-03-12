"""API package — registers all routers."""

from fastapi import FastAPI

from app.api.health import router as health_router
from app.api.meetings import router as meetings_router
from app.api.transcript import router as transcript_router
from app.api.people import router as people_router
from app.api.summaries import router as summaries_router


def register_routers(app: FastAPI) -> None:
    app.include_router(health_router)
    app.include_router(meetings_router)
    app.include_router(transcript_router)
    app.include_router(people_router)
    app.include_router(summaries_router)
