"""Google Gemini summarization provider."""

from __future__ import annotations

import json

from app.core.config import settings
from app.services.summarization.base import SummarizationProvider, SummaryResult
from app.services.summarization.prompt_builder import _load_system_prompt, build_messages, parse_summary_json

# Most affordable stable Gemini model — "fastest and most budget-friendly" per Google docs.
DEFAULT_MODEL = "gemini-2.5-flash-lite"


class GeminiProvider(SummarizationProvider):
    """Uses the Google Gemini API via the google-generativeai SDK."""

    def summarize(self, transcript_text: str, model: str = DEFAULT_MODEL) -> SummaryResult:
        try:
            import google.generativeai as genai
        except ImportError as e:
            raise RuntimeError(
                "google-generativeai package is required. Run: pip install google-generativeai"
            ) from e

        api_key = settings.gemini_api_key
        if not api_key:
            raise RuntimeError("GEMINI_API_KEY is not configured.")

        genai.configure(api_key=api_key)

        # Force JSON output via response_mime_type — no post-processing needed.
        generation_config = genai.GenerationConfig(
            response_mime_type="application/json",
            temperature=0.2,
        )

        system_prompt = _load_system_prompt()
        gemini_model = genai.GenerativeModel(
            model_name=model,
            system_instruction=system_prompt,
            generation_config=generation_config,
        )

        messages = build_messages(transcript_text)
        user_content = next(
            (m["content"] for m in messages if m["role"] == "user"), transcript_text
        )

        response = gemini_model.generate_content(user_content)
        raw_text = response.text if response.text else ""

        if not raw_text:
            raise RuntimeError(f"Gemini returned an empty response for model '{model}'.")

        try:
            raw_json = json.loads(raw_text)
        except json.JSONDecodeError:
            from app.services.summarization.ollama_provider import _extract_json
            raw_json = _extract_json(raw_text)
            if raw_json is None:
                return SummaryResult(markdown=raw_text, meeting_summary=raw_text, raw_json={})

        return parse_summary_json(raw_json)
