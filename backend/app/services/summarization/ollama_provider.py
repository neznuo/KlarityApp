"""Ollama local LLM summarization provider."""

from __future__ import annotations
from typing import Optional

import json

import httpx

from app.core.config import settings
from app.services.summarization.base import SummarizationProvider, SummaryResult
from app.services.summarization.prompt_builder import build_messages, parse_summary_json


class OllamaProvider(SummarizationProvider):
    """
    Calls a local Ollama instance via the /api/chat endpoint.

    Uses think=False so that thinking models (qwen3, deepseek-r1, etc.) return
    their output in message.content instead of the thinking field, which is
    invisible to the standard response parser.
    """

    def summarize(self, transcript_text: str, model: str = "llama3") -> SummaryResult:
        endpoint = settings.ollama_endpoint.rstrip("/")
        url = f"{endpoint}/api/chat"
        messages = build_messages(transcript_text)

        payload = {
            "model": model,
            "messages": messages,
            "stream": False,
            "think": False,   # disable extended thinking for qwen3/deepseek-r1 etc.
            "format": "json",
        }

        with httpx.Client(timeout=300.0) as client:
            response = client.post(url, json=payload)
            if response.status_code != 200:
                raise RuntimeError(
                    f"Ollama returned HTTP {response.status_code}: {response.text[:500]}"
                )

        data = response.json()
        raw_text = data.get("message", {}).get("content", "")

        if not raw_text:
            raise RuntimeError(
                f"Ollama returned an empty response for model '{model}'. "
                "Ensure the model is pulled and the endpoint is reachable."
            )

        try:
            raw_json = json.loads(raw_text)
        except json.JSONDecodeError:
            # Last-resort: extract a JSON block from the text if the model leaked
            # extra prose despite format=json
            raw_json = _extract_json(raw_text)
            if raw_json is None:
                return SummaryResult(markdown=raw_text, meeting_summary=raw_text, raw_json={})

        return parse_summary_json(raw_json)


def _extract_json(text: str) -> Optional[dict]:
    """Try to pull a JSON object out of a text response that contains extra prose."""
    start = text.find("{")
    end = text.rfind("}") + 1
    if start == -1 or end == 0:
        return None
    try:
        return json.loads(text[start:end])
    except json.JSONDecodeError:
        return None
