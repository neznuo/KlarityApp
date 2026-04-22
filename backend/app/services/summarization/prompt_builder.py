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
    """Single-string prompt for /api/generate style endpoints (OpenAI, Anthropic)."""
    system = _load_system_prompt()
    return f"{system}\n\n---\n\nMEETING TRANSCRIPT:\n{transcript_text}\n\n---\n\nRespond ONLY with valid JSON matching the schema above."


def build_messages(transcript_text: str) -> list[dict]:
    """Chat-style messages list for /api/chat endpoints (Ollama, etc.).
    Splitting system instructions from transcript gives better results and
    avoids thinking-model artifacts when think=False is set.
    """
    system = _load_system_prompt()
    return [
        {"role": "system", "content": system},
        {
            "role": "user",
            "content": (
                f"MEETING TRANSCRIPT:\n{transcript_text}\n\n"
                "Respond ONLY with valid JSON matching the schema above."
            ),
        },
    ]


def parse_summary_json(data: dict) -> SummaryResult:
    """Map provider JSON response to a SummaryResult."""
    result = SummaryResult(
        meeting_summary=data.get("meeting_summary", ""),
        topics_discussed=data.get("topics_discussed", []),
        key_decisions=data.get("key_decisions", []),
        action_items=data.get("action_items", []),
        open_questions=data.get("open_questions", []),
        risks_and_blockers=data.get("risks_and_blockers", []),
        key_insights=data.get("key_insights", []),
        next_steps_summary=data.get("next_steps_summary", ""),
        follow_up_email=data.get("follow_up_email", ""),
        # Legacy field from old-schema summaries
        risks=data.get("risks", []),
        raw_json=data,
    )
    result.markdown = _build_markdown(result)
    return result


def _build_markdown(r: SummaryResult) -> str:  # noqa: C901
    lines = ["# Meeting Summary", "", r.meeting_summary, ""]

    # ── Topics Discussed ─────────────────────────────────────────────────────
    if r.topics_discussed:
        lines += ["## Topics Discussed", ""]
        _OUTCOME_LABEL = {
            "resolved":      "✅ Resolved",
            "deferred":      "⏸ Deferred",
            "in_progress":   "🔄 In Progress",
            "informational": "ℹ️ Informational",
            "no_consensus":  "❓ No Consensus",
        }
        for item in r.topics_discussed:
            if isinstance(item, dict):
                topic = item.get("topic", "")
                summary = item.get("summary", "")
                outcome_key = item.get("outcome", "")
                outcome_label = _OUTCOME_LABEL.get(outcome_key, outcome_key)
                header = f"### {topic}"
                if outcome_label:
                    header += f"  _{outcome_label}_"
                lines += [header, "", summary, ""]
            else:
                lines.append(f"- {item}")
        lines.append("")

    # ── Key Decisions ────────────────────────────────────────────────────────
    if r.key_decisions:
        lines += ["## Key Decisions", ""]
        for d in r.key_decisions:
            if isinstance(d, dict):
                decision = d.get("decision", str(d))
                rationale = d.get("rationale", "")
                decided_by = d.get("decided_by", "")
                line = f"- {decision}"
                if decided_by:
                    line += f" _(by {decided_by})_"
                lines.append(line)
                if rationale:
                    lines.append(f"  > {rationale}")
            else:
                lines.append(f"- {d}")
        lines.append("")

    # ── Action Items ─────────────────────────────────────────────────────────
    if r.action_items:
        lines += ["## Action Items", ""]
        _PRIORITY_BADGE = {"high": "🔴", "medium": "🟡", "low": "🟢"}
        for item in r.action_items:
            owner = item.get("owner", "")
            task = item.get("task", str(item))
            due = item.get("due_date", "")
            priority = item.get("priority", "")
            context = item.get("context", "")
            badge = _PRIORITY_BADGE.get(priority, "")
            owner_str = f"**{owner}**: " if owner else ""
            due_str = f" _(due: {due})_" if due else ""
            priority_str = f" {badge}" if badge else ""
            lines.append(f"- {owner_str}{task}{due_str}{priority_str}")
            if context:
                lines.append(f"  > {context}")
        lines.append("")

    # ── Open Questions ────────────────────────────────────────────────────────
    if r.open_questions:
        lines += ["## Open Questions", ""]
        for q in r.open_questions:
            if isinstance(q, dict):
                question = q.get("question", str(q))
                raised_by = q.get("raised_by", "")
                assigned_to = q.get("assigned_to", "")
                line = f"- {question}"
                if raised_by:
                    line += f" _(raised by {raised_by})_"
                if assigned_to:
                    line += f" → **{assigned_to}** to answer"
                lines.append(line)
            else:
                lines.append(f"- {q}")
        lines.append("")

    # ── Risks & Blockers (new schema) or fallback to legacy risks list ────────
    blockers = r.risks_and_blockers or [
        {"type": "risk", "description": risk, "severity": "", "mitigation": ""}
        for risk in r.risks
    ]
    if blockers:
        lines += ["## Risks & Blockers", ""]
        _TYPE_ICON = {"risk": "⚠️", "blocker": "🚫", "dependency": "🔗", "concern": "💬"}
        _SEV_BADGE = {"high": " `high`", "medium": " `medium`", "low": " `low`"}
        for item in blockers:
            if isinstance(item, dict):
                type_ = item.get("type", "risk")
                desc = item.get("description", str(item))
                severity = item.get("severity", "")
                mitigation = item.get("mitigation", "")
                icon = _TYPE_ICON.get(type_, "•")
                sev = _SEV_BADGE.get(severity, "")
                lines.append(f"- {icon} **{type_.title()}**{sev}: {desc}")
                if mitigation:
                    lines.append(f"  > Mitigation: {mitigation}")
            else:
                lines.append(f"- {item}")
        lines.append("")

    # ── Key Insights ──────────────────────────────────────────────────────────
    if r.key_insights:
        lines += ["## Key Insights", ""]
        for insight in r.key_insights:
            lines.append(f"- {insight}")
        lines.append("")

    # ── Next Steps ────────────────────────────────────────────────────────────
    if r.next_steps_summary:
        lines += ["## Next Steps", "", r.next_steps_summary, ""]

    # ── Follow-up Email ───────────────────────────────────────────────────────
    if r.follow_up_email:
        lines += ["## Follow-up Email Draft", "", r.follow_up_email, ""]

    return "\n".join(lines)


# Inline fallback prompt used when summary_prompt.txt is absent
INLINE_PROMPT = """You are an expert meeting analyst. Analyze the meeting transcript and return ONLY a valid JSON object.

SCHEMA:
{
  "meeting_summary": "3-5 sentence executive overview",
  "topics_discussed": [{"topic": "Name", "summary": "What was discussed", "outcome": "resolved|deferred|in_progress|informational|no_consensus"}],
  "key_decisions": [{"decision": "What was decided", "rationale": "Why, or empty string", "decided_by": "Who, or empty string"}],
  "action_items": [{"owner": "Name or empty string", "task": "Description", "due_date": "YYYY-MM-DD or empty string", "priority": "high|medium|low", "context": "Why this task, or empty string"}],
  "open_questions": [{"question": "Unresolved question", "raised_by": "Name or empty string", "assigned_to": "Name or empty string"}],
  "risks_and_blockers": [{"type": "risk|blocker|dependency|concern", "description": "Description", "severity": "high|medium|low", "mitigation": "Any mitigation or empty string"}],
  "key_insights": ["Notable insight that doesn't fit other sections"],
  "next_steps_summary": "3-5 sentence paragraph on what happens next",
  "follow_up_email": "Complete professional follow-up email draft"
}

RULES FOR action_items — READ CAREFULLY:
1. Capture EVERY task, to-do, follow-up, or commitment mentioned anywhere in the transcript — even if stated indirectly or casually (e.g. "I'll handle that", "someone should", "we need to", "let's make sure").
2. ALSO examine each key_decision: if a decision implies someone needs to DO something to implement or follow through on it, create a corresponding action_item. Do not leave decisions as mere notes if they have an actionable consequence.
3. Include tasks implied by open questions assigned to someone (e.g. "John will look into this").
4. If an owner name is mentioned, include it. Do NOT leave owner blank if a name was said.
5. Assign priority: high = blocking or time-sensitive, medium = important but not urgent, low = nice-to-have.
6. Be LIBERAL — it is better to include too many tasks than to miss one.

GENERAL RULES:
- Do NOT fabricate names, owners, or dates not mentioned in the transcript.
- Return valid JSON only. No markdown fences, no commentary."""
