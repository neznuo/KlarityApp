"""OpenAI GPT summarization provider."""

from __future__ import annotations

import json

from app.core.config import settings
from app.services.summarization.base import SummarizationProvider, SummaryResult
from app.services.summarization.prompt_builder import build_messages, parse_summary_json

# Most affordable model that handles structured summarization well.
DEFAULT_MODEL = "gpt-4o-mini"


class OpenAIProvider(SummarizationProvider):
    """Uses the OpenAI Chat Completions API."""

    def summarize(self, transcript_text: str, model: str = DEFAULT_MODEL) -> SummaryResult:
        try:
            from openai import OpenAI
        except ImportError as e:
            raise RuntimeError("openai package is required. Run: pip install openai") from e

        api_key = settings.openai_api_key
        if not api_key:
            raise RuntimeError("OPENAI_API_KEY is not configured.")

        client = OpenAI(api_key=api_key)

        response = client.chat.completions.create(
            model=model,
            messages=build_messages(transcript_text),
            response_format={"type": "json_object"},
            temperature=0.2,
        )
        raw_text = response.choices[0].message.content or "{}"

        try:
            raw_json = json.loads(raw_text)
        except json.JSONDecodeError:
            return SummaryResult(markdown=raw_text, meeting_summary=raw_text, raw_json={})

        return parse_summary_json(raw_json)
