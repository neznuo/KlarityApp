"""
LLM summarization provider abstraction.

To add a new provider:
1. Subclass SummarizationProvider
2. Implement .summarize()
3. Register it in get_provider()
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field


@dataclass
class SummaryResult:
    meeting_summary: str = ""
    key_decisions: list[str] = field(default_factory=list)
    action_items: list[dict] = field(default_factory=list)   # [{owner, task, due_date}]
    risks: list[str] = field(default_factory=list)
    follow_up_email: str = ""
    raw_json: dict = field(default_factory=dict)
    markdown: str = ""


class SummarizationProvider(ABC):
    """Base class for all LLM summarization backends."""

    @abstractmethod
    def summarize(self, transcript_text: str, model: str) -> SummaryResult:
        """
        Given a formatted transcript string, produce a structured summary.
        Raises RuntimeError on provider errors.
        """
        ...


def get_provider(name: str) -> SummarizationProvider:
    """Factory — returns provider instance by name."""
    if name == "openai":
        from app.services.summarization.openai_provider import OpenAIProvider
        return OpenAIProvider()
    if name == "ollama":
        from app.services.summarization.ollama_provider import OllamaProvider
        return OllamaProvider()
    if name == "anthropic":
        from app.services.summarization.anthropic_provider import AnthropicProvider
        return AnthropicProvider()
    raise ValueError(f"Unknown summarization provider: {name!r}")
