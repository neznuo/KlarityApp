"""OpenAI GPT summarization provider."""

from __future__ import annotations

import json

from app.core.config import settings
from app.services.summarization.base import SummarizationProvider, SummaryResult
from app.services.summarization.prompt_builder import build_prompt, parse_summary_json


class OpenAIProvider(SummarizationProvider):
    """Uses the OpenAI Chat Completions API."""

    def summarize(self, transcript_text: str, model: str = "gpt-4o") -> SummaryResult:
        try:
            from openai import OpenAI
        except ImportError as e:
            raise RuntimeError("openai package is required") from e

        api_key = settings.openai_api_key
        if not api_key:
            raise RuntimeError("OPENAI_API_KEY is not configured.")

        client = OpenAI(api_key=api_key)
        prompt = build_prompt(transcript_text)

        response = client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            response_format={"type": "json_object"},
            temperature=0.3,
        )
        raw_text = response.choices[0].message.content or "{}"
        raw_json = json.loads(raw_text)
        return parse_summary_json(raw_json)
