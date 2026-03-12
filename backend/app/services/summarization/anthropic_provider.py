"""Anthropic Claude summarization provider."""

from __future__ import annotations

import json

from app.core.config import settings
from app.services.summarization.base import SummarizationProvider, SummaryResult
from app.services.summarization.prompt_builder import build_prompt, parse_summary_json


class AnthropicProvider(SummarizationProvider):
    """Uses Anthropic Claude via the Messages API."""

    def summarize(self, transcript_text: str, model: str = "claude-3-5-sonnet-20241022") -> SummaryResult:
        try:
            import anthropic
        except ImportError as e:
            raise RuntimeError("anthropic package is required") from e

        api_key = settings.anthropic_api_key
        if not api_key:
            raise RuntimeError("ANTHROPIC_API_KEY is not configured.")

        client = anthropic.Anthropic(api_key=api_key)
        prompt = build_prompt(transcript_text)

        message = client.messages.create(
            model=model,
            max_tokens=4096,
            messages=[{"role": "user", "content": prompt}],
        )
        raw_text = message.content[0].text if message.content else "{}"

        try:
            raw_json = json.loads(raw_text)
        except json.JSONDecodeError:
            return SummaryResult(markdown=raw_text, meeting_summary=raw_text)

        return parse_summary_json(raw_json)
