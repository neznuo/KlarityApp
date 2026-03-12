"""Ollama local LLM summarization provider."""

from __future__ import annotations

import json

import httpx

from app.core.config import settings
from app.services.summarization.base import SummarizationProvider, SummaryResult
from app.services.summarization.prompt_builder import build_prompt, parse_summary_json


class OllamaProvider(SummarizationProvider):
    """Calls a local Ollama instance via REST API."""

    def summarize(self, transcript_text: str, model: str = "llama3") -> SummaryResult:
        endpoint = settings.ollama_endpoint.rstrip("/")
        url = f"{endpoint}/api/generate"
        prompt = build_prompt(transcript_text)

        payload = {
            "model": model,
            "prompt": prompt,
            "stream": False,
            "format": "json",
        }

        with httpx.Client(timeout=300.0) as client:
            response = client.post(url, json=payload)
            if response.status_code != 200:
                raise RuntimeError(
                    f"Ollama returned HTTP {response.status_code}: {response.text}"
                )

        data = response.json()
        raw_text = data.get("response", "{}")

        try:
            raw_json = json.loads(raw_text)
        except json.JSONDecodeError:
            # Fallback: treat the raw response as the markdown summary
            return SummaryResult(markdown=raw_text, meeting_summary=raw_text)

        return parse_summary_json(raw_json)
