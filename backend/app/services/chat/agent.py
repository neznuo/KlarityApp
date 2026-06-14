"""
AI Chat agent — multi-provider tool-calling loop.

Supports OpenAI, Anthropic, Gemini, and Ollama.
Each provider gets its own adapter that normalises the API differences into a
common "run one step" interface: given a list of messages, either return a
text token to stream, or a tool-call the agent should execute.
"""

from __future__ import annotations

import json
import logging
from typing import AsyncGenerator, Any

from sqlalchemy.orm import Session

from app.core.config import settings
from app.services.chat.tools import TOOL_DEFINITIONS, TOOL_REGISTRY

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """\
You are Klarity Assistant, an AI integrated into the Klarity meeting intelligence app.
You have access to all recorded meetings, transcripts, AI-generated summaries, \
action items, and contacts stored in this user's Klarity account.

Use the provided tools to look up real data before answering.  Always cite the \
meeting source (name and date) when referencing specific information so the user \
can navigate to it.

Be concise. Use bullet lists for tasks/decisions. When results are empty, say so clearly.
"""


# ─── Provider Adapters ────────────────────────────────────────────────────────

async def _run_openai(
    messages: list[dict],
    model: str,
    db: Session,
) -> AsyncGenerator[str, None]:
    """OpenAI function-calling loop with streaming final response."""
    try:
        from openai import AsyncOpenAI
    except ImportError as exc:
        raise RuntimeError("openai package required: pip install openai") from exc

    api_key = settings.openai_api_key
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is not configured in Settings.")

    client = AsyncOpenAI(api_key=api_key)
    tools_schema = [{"type": "function", "function": t} for t in TOOL_DEFINITIONS]

    # Agentic loop — max 5 tool-call rounds to prevent runaway loops
    for _ in range(5):
        resp = await client.chat.completions.create(
            model=model or "gpt-4o-mini",
            messages=messages,
            tools=tools_schema,
            tool_choice="auto",
            stream=False,
            temperature=0.2,
        )
        choice = resp.choices[0]

        if choice.finish_reason == "tool_calls":
            tool_calls = choice.message.tool_calls or []
            messages.append(choice.message.model_dump())

            for tc in tool_calls:
                fn_name = tc.function.name
                fn_args = json.loads(tc.function.arguments or "{}")
                result = _dispatch_tool(fn_name, fn_args, db)
                messages.append({
                    "role": "tool",
                    "tool_call_id": tc.id,
                    "content": json.dumps(result),
                })
            continue  # next loop iteration with tool results injected

        # Final text answer — stream it token by token via a second streaming call
        stream = await client.chat.completions.create(
            model=model or "gpt-4o-mini",
            messages=messages,
            temperature=0.2,
            stream=True,
        )
        async for chunk in stream:
            delta = chunk.choices[0].delta.content
            if delta:
                yield delta
        return

    yield "\n\n*(Max tool-call depth reached)*"


async def _run_anthropic(
    messages: list[dict],
    model: str,
    db: Session,
) -> AsyncGenerator[str, None]:
    """Anthropic Claude tool-calling loop."""
    try:
        import anthropic as ant
    except ImportError as exc:
        raise RuntimeError("anthropic package required: pip install anthropic") from exc

    api_key = settings.anthropic_api_key
    if not api_key:
        raise RuntimeError("ANTHROPIC_API_KEY is not configured in Settings.")

    client = ant.AsyncAnthropic(api_key=api_key)

    # Anthropic separates system from messages
    system_msg = SYSTEM_PROMPT
    ant_messages = [m for m in messages if m["role"] != "system"]
    ant_tools = [
        {"name": t["name"], "description": t["description"], "input_schema": t["parameters"]}
        for t in TOOL_DEFINITIONS
    ]

    for _ in range(5):
        resp = await client.messages.create(
            model=model or "claude-3-5-haiku-latest",
            max_tokens=2048,
            system=system_msg,
            messages=ant_messages,
            tools=ant_tools,
        )

        if resp.stop_reason == "tool_use":
            tool_results = []
            assistant_content = []
            for block in resp.content:
                assistant_content.append(block.model_dump())
                if block.type == "tool_use":
                    result = _dispatch_tool(block.name, block.input, db)
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": json.dumps(result),
                    })
            ant_messages.append({"role": "assistant", "content": assistant_content})
            ant_messages.append({"role": "user", "content": tool_results})
            continue

        # Stream the final text
        async with client.messages.stream(
            model=model or "claude-3-5-haiku-latest",
            max_tokens=2048,
            system=system_msg,
            messages=ant_messages,
        ) as stream:
            async for text_chunk in stream.text_stream:
                yield text_chunk
        return

    yield "\n\n*(Max tool-call depth reached)*"


async def _run_gemini(
    messages: list[dict],
    model: str,
    db: Session,
) -> AsyncGenerator[str, None]:
    """Google Gemini tool-calling loop."""
    try:
        import google.generativeai as genai
    except ImportError as exc:
        raise RuntimeError("google-generativeai package required: pip install google-generativeai") from exc

    api_key = settings.gemini_api_key
    if not api_key:
        raise RuntimeError("GEMINI_API_KEY is not configured in Settings.")

    genai.configure(api_key=api_key)

    # Convert TOOL_DEFINITIONS to Gemini FunctionDeclaration format
    from google.generativeai.types import FunctionDeclaration, Tool as GeminiTool

    declarations = [
        FunctionDeclaration(
            name=t["name"],
            description=t["description"],
            parameters=t["parameters"],
        )
        for t in TOOL_DEFINITIONS
    ]
    gemini_tools = [GeminiTool(function_declarations=declarations)]

    gemini_model = genai.GenerativeModel(
        model_name=model or "gemini-1.5-flash",
        system_instruction=SYSTEM_PROMPT,
        tools=gemini_tools,
    )

    # Convert OpenAI-style messages to Gemini history
    history = []
    user_text = ""
    for m in messages:
        role = m["role"]
        if role == "system":
            continue
        if role == "user":
            user_text = m["content"]
        elif role == "assistant":
            history.append({"role": "model", "parts": [m["content"]]})

    chat = gemini_model.start_chat(history=history)

    for _ in range(5):
        resp = chat.send_message(user_text)
        candidate = resp.candidates[0]

        # Check for function calls
        fn_parts = [p for p in candidate.content.parts if p.function_call.name]
        if fn_parts:
            tool_responses = []
            for part in fn_parts:
                fc = part.function_call
                result = _dispatch_tool(fc.name, dict(fc.args), db)
                from google.generativeai.types import content_types
                tool_responses.append(
                    genai.protos.Part(
                        function_response=genai.protos.FunctionResponse(
                            name=fc.name,
                            response={"result": result},
                        )
                    )
                )
            user_text = ""
            resp = chat.send_message(tool_responses)
            candidate = resp.candidates[0]

        # Yield text from response
        for part in candidate.content.parts:
            if hasattr(part, "text") and part.text:
                yield part.text
        return

    yield "\n\n*(Max tool-call depth reached)*"


async def _run_ollama(
    messages: list[dict],
    model: str,
    db: Session,
) -> AsyncGenerator[str, None]:
    """Ollama tool-calling (supported by llama3.1+, qwen2.5, mistral-nemo, etc.)."""
    try:
        import httpx
    except ImportError as exc:
        raise RuntimeError("httpx package required: pip install httpx") from exc

    endpoint = (settings.ollama_endpoint or "http://localhost:11434").rstrip("/")
    url = f"{endpoint}/api/chat"
    tools_schema = [{"type": "function", "function": t} for t in TOOL_DEFINITIONS]

    for _ in range(5):
        payload = {
            "model":    model or "llama3.1",
            "messages": messages,
            "tools":    tools_schema,
            "stream":   False,
        }
        async with httpx.AsyncClient(timeout=120) as http:
            r = await http.post(url, json=payload)
            r.raise_for_status()
            data = r.json()

        msg = data.get("message", {})
        tool_calls = msg.get("tool_calls") or []

        if tool_calls:
            messages.append(msg)
            for tc in tool_calls:
                fn = tc.get("function", {})
                fn_name = fn.get("name", "")
                fn_args = fn.get("arguments", {})
                if isinstance(fn_args, str):
                    fn_args = json.loads(fn_args)
                result = _dispatch_tool(fn_name, fn_args, db)
                messages.append({
                    "role":    "tool",
                    "content": json.dumps(result),
                })
            continue

        # Stream the final answer via /api/chat stream=True
        payload["stream"] = True
        payload["messages"] = messages
        async with httpx.AsyncClient(timeout=120) as http:
            async with http.stream("POST", url, json=payload) as stream_resp:
                async for line in stream_resp.aiter_lines():
                    if not line.strip():
                        continue
                    try:
                        chunk = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    token = chunk.get("message", {}).get("content", "")
                    if token:
                        yield token
                    if chunk.get("done"):
                        break
        return

    yield "\n\n*(Max tool-call depth reached)*"


# ─── Tool Dispatcher ──────────────────────────────────────────────────────────

def _dispatch_tool(name: str, args: dict, db: Session) -> Any:
    """Call the registered tool function, returning a JSON-serialisable result."""
    fn = TOOL_REGISTRY.get(name)
    if fn is None:
        return {"error": f"Unknown tool: {name!r}"}
    try:
        return fn(db, **args)
    except Exception as exc:
        logger.exception("Tool %r raised an exception", name)
        return {"error": str(exc)}


# ─── Public Entry Point ───────────────────────────────────────────────────────

async def run_chat_agent(
    *,
    provider: str,
    model: str,
    conversation: list[dict],
    db: Session,
) -> AsyncGenerator[str, None]:
    """Run one user turn through the appropriate LLM provider.

    Args:
        provider:     "openai" | "anthropic" | "gemini" | "ollama"
        model:        Provider-specific model name (or "" for provider default).
        conversation: Full message history INCLUDING the new user message.
                      Each entry: {"role": "system"|"user"|"assistant", "content": str}
        db:           Active SQLAlchemy session.

    Yields:
        Text tokens as they are generated.
    """
    # Always prepend the system prompt unless caller already provided one
    if not conversation or conversation[0]["role"] != "system":
        conversation = [{"role": "system", "content": SYSTEM_PROMPT}] + conversation

    provider = (provider or "").lower().strip()

    if provider == "openai":
        gen = _run_openai(conversation, model, db)
    elif provider == "anthropic":
        gen = _run_anthropic(conversation, model, db)
    elif provider == "gemini":
        gen = _run_gemini(conversation, model, db)
    elif provider == "ollama":
        gen = _run_ollama(conversation, model, db)
    else:
        raise ValueError(f"Unsupported chat provider: {provider!r}. Choose from: openai, anthropic, gemini, ollama.")

    async for token in gen:
        yield token
