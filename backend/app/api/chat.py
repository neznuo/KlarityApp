"""Chat API — POST /chat streams an SSE response from the AI agent."""

from __future__ import annotations

import json
import logging

from fastapi import APIRouter, Depends
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.db.database import get_db
from app.services.chat.agent import run_chat_agent

router = APIRouter(prefix="/chat", tags=["Chat"])
logger = logging.getLogger(__name__)


# ─── Schemas ──────────────────────────────────────────────────────────────────

class ChatMessage(BaseModel):
    role: str = Field(..., description="'user' or 'assistant'")
    content: str


class ChatRequest(BaseModel):
    provider: str = Field(
        "openai",
        description="LLM provider: 'openai', 'anthropic', 'gemini', or 'ollama'",
    )
    model: str = Field(
        "",
        description="Provider-specific model name. Leave blank to use the provider default.",
    )
    messages: list[ChatMessage] = Field(
        ...,
        description="Full conversation history. The last message must be from the user.",
    )


# ─── SSE helpers ──────────────────────────────────────────────────────────────

def _sse(event: str, data: str) -> str:
    """Format a single Server-Sent Event frame."""
    return f"event: {event}\ndata: {json.dumps(data)}\n\n"


async def _stream_response(
    provider: str, model: str, conversation: list[dict], db: Session
):
    """Async generator that yields SSE frames."""
    try:
        async for token in run_chat_agent(
            provider=provider,
            model=model,
            conversation=conversation,
            db=db,
        ):
            yield _sse("token", token)
        yield _sse("done", "")
    except Exception as exc:
        logger.exception("Chat agent error")
        yield _sse("error", str(exc))


# ─── Endpoint ─────────────────────────────────────────────────────────────────

@router.post("")
async def chat(
    payload: ChatRequest,
    db: Session = Depends(get_db),
):
    """
    Stream an AI response to a conversation.

    The response is a Server-Sent Events stream.  Each frame is one of:

    * `event: token` — a text token to append to the message
    * `event: done`  — the response is complete
    * `event: error` — an error occurred; `data` contains the message
    """
    conversation = [{"role": m.role, "content": m.content} for m in payload.messages]

    return StreamingResponse(
        _stream_response(payload.provider, payload.model, conversation, db),
        media_type="text/event-stream",
        headers={
            "Cache-Control":    "no-cache",
            "X-Accel-Buffering": "no",
        },
    )
