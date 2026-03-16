"""Anthropic Claude summarization provider."""

from __future__ import annotations

import json

from app.core.config import settings
from app.services.summarization.base import SummarizationProvider, SummaryResult
from app.services.summarization.prompt_builder import _load_system_prompt, build_messages, parse_summary_json

# Most affordable Claude model — fast and accurate for structured extraction.
DEFAULT_MODEL = "claude-3-5-haiku-20241022"


class AnthropicProvider(SummarizationProvider):
    """Uses Anthropic Claude via the Messages API."""

    def summarize(self, transcript_text: str, model: str = DEFAULT_MODEL) -> SummaryResult:
        try:
            import anthropic
        except ImportError as e:
            raise RuntimeError("anthropic package is required. Run: pip install anthropic") from e

        api_key = settings.anthropic_api_key
        if not api_key:
            raise RuntimeError("ANTHROPIC_API_KEY is not configured.")

        client = anthropic.Anthropic(api_key=api_key)
        messages = build_messages(transcript_text)

        # Anthropic takes system as a top-level param — pull it out of the messages list.
        system_content = next((m["content"] for m in messages if m["role"] == "system"), "")
        user_messages = [m for m in messages if m["role"] != "system"]

        message = client.messages.create(
            model=model,
            max_tokens=2048,
            system=system_content,
            messages=user_messages,
        )
        raw_text = message.content[0].text if message.content else ""

        if not raw_text:
            raise RuntimeError(f"Anthropic returned an empty response for model '{model}'.")

        try:
            raw_json = json.loads(raw_text)
        except json.JSONDecodeError:
            from app.services.summarization.ollama_provider import _extract_json
            raw_json = _extract_json(raw_text)
            if raw_json is None:
                return SummaryResult(markdown=raw_text, meeting_summary=raw_text, raw_json={})

        return parse_summary_json(raw_json)
