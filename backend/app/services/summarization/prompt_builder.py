"""Shared prompt builder and response parser for all summarization providers."""

from __future__ import annotations

from pathlib import Path

from app.services.summarization.base import SummaryResult

_PROMPT_TEMPLATE_PATH = Path(__file__).parent.parent.parent / "prompts" / "summary_prompt.txt"


def _load_system_prompt() -> str:
    if _PROMPT_TEMPLATE_PATH.exists():
        return _PROMPT_TEMPLATE_PATH.read_text()
    # Inline fallback if file is missing
    return INLINE_PROMPT


def build_prompt(transcript_text: str) -> str:
    """Combine system instructions with the transcript text."""
    system = _load_system_prompt()
    return f"{system}\n\n---\n\nMEETING TRANSCRIPT:\n{transcript_text}\n\n---\n\nRespond ONLY with valid JSON matching the schema above."


def parse_summary_json(data: dict) -> SummaryResult:
    """Map provider JSON response to a SummaryResult."""
    result = SummaryResult(
        meeting_summary=data.get("meeting_summary", ""),
        key_decisions=data.get("key_decisions", []),
        action_items=data.get("action_items", []),
        risks=data.get("risks", []),
        follow_up_email=data.get("follow_up_email", ""),
        raw_json=data,
    )
    result.markdown = _build_markdown(result)
    return result


def _build_markdown(r: SummaryResult) -> str:
    lines = ["# Meeting Summary", "", r.meeting_summary, ""]

    if r.key_decisions:
        lines += ["## Key Decisions", ""]
        for d in r.key_decisions:
            lines.append(f"- {d}")
        lines.append("")

    if r.action_items:
        lines += ["## Action Items", ""]
        for item in r.action_items:
            owner = item.get("owner", "")
            task = item.get("task", str(item))
            due = item.get("due_date", "")
            due_str = f" _(due: {due})_" if due else ""
            owner_str = f"**{owner}**: " if owner else ""
            lines.append(f"- {owner_str}{task}{due_str}")
        lines.append("")

    if r.risks:
        lines += ["## Risks", ""]
        for risk in r.risks:
            lines.append(f"- {risk}")
        lines.append("")

    if r.follow_up_email:
        lines += ["## Follow-up Email Draft", "", r.follow_up_email, ""]

    return "\n".join(lines)


# Inline fallback prompt used when summary_prompt.txt is absent
INLINE_PROMPT = """You are a professional meeting analyst. Analyze the following meeting transcript and produce a structured JSON summary.

Return a JSON object with these fields ONLY — do not fabricate owners or due dates unless explicitly mentioned:

{
  "meeting_summary": "2-4 sentence overview of what was discussed",
  "key_decisions": ["Decision 1", "Decision 2"],
  "action_items": [
    {"owner": "Name or empty string", "task": "Description", "due_date": "YYYY-MM-DD or empty string"}
  ],
  "risks": ["Risk 1", "Risk 2"],
  "follow_up_email": "A brief professional follow-up email draft"
}"""
