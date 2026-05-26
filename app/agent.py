import json
import os
from typing import Any, Callable, Dict, List, Optional

from anthropic import Anthropic


SERVICE_NAME = os.environ.get("SERVICE_NAME", "hello-world-agent")
VERSION = os.environ.get("VERSION", "0.1.0")
CLOUD_PROVIDER = os.environ.get("CLOUD_PROVIDER", "local")

ANTHROPIC_MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-3-5-sonnet-latest")
ANTHROPIC_MAX_TOKENS = int(os.environ.get("ANTHROPIC_MAX_TOKENS", "800"))
ANTHROPIC_TEMPERATURE = float(os.environ.get("ANTHROPIC_TEMPERATURE", "0"))


def get_service_metadata() -> Dict[str, str]:
    return {
        "service": SERVICE_NAME,
        "version": VERSION,
        "cloud_provider": CLOUD_PROVIDER,
    }


def health_check() -> Dict[str, str]:
    return {"status": "ok"}


def echo(text: str) -> Dict[str, str]:
    return {"echo": text}


ToolFunc = Callable[..., Dict[str, Any]]


TOOLS: List[Dict[str, Any]] = [
    {
        "name": "get_service_metadata",
        "description": "Return service metadata for this deployed agent.",
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "health_check",
        "description": "Return service health status.",
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "echo",
        "description": "Echo back a string (useful for testing).",
        "input_schema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
    },
]

TOOL_FUNCS: Dict[str, ToolFunc] = {
    "get_service_metadata": get_service_metadata,
    "health_check": health_check,
    "echo": echo,
}


class AgentConfigError(RuntimeError):
    pass


def _require_anthropic_key() -> None:
    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise AgentConfigError(
            "Missing ANTHROPIC_API_KEY. Set it in your environment (or deploy-time env vars)."
        )


def _extract_text(content_blocks: List[Any]) -> str:
    texts: List[str] = []
    for block in content_blocks:
        if getattr(block, "type", None) == "text":
            texts.append(getattr(block, "text", ""))
    return "".join(texts).strip()


POLICY_SYSTEM_PROMPT = """You are a small policy agent running inside a deployed service.

You must return ONLY valid JSON (no markdown, no extra text) with this exact shape:
{
  "decision": "allow" | "block" | "review",
  "category": "general" | "pii" | "credentials" | "malware",
  "reason": "short explanation",
  "service_context": {"service": "...", "version": "...", "cloud_provider": "..."}
}

Rules:
- Use "block" for obvious secrets (API keys, private keys, access tokens) or malware-like requests.
- Use "review" when it might include PII (emails/phones) or uncertain sensitive info.
- Otherwise "allow".
- Populate service_context from the tool result of get_service_metadata.
"""


def _find_tool_use(content_blocks: List[Any], tool_name: str) -> Optional[Any]:
    for block in content_blocks:
        if getattr(block, "type", None) == "tool_use" and getattr(block, "name", None) == tool_name:
            return block
    return None


def _append_tool_result(
    *,
    messages: List[Dict[str, Any]],
    tool_results: List[Dict[str, Any]],
    tool_use: Any,
    result_obj: Dict[str, Any],
) -> None:
    tool_name = getattr(tool_use, "name", None)
    tool_use_id = getattr(tool_use, "id", None)
    tool_input = getattr(tool_use, "input", None) or {}

    tool_results.append(
        {
            "tool_name": tool_name,
            "tool_use_id": tool_use_id,
            "input": tool_input,
            "output": result_obj,
        }
    )

    messages.append(
        {
            "role": "user",
            "content": [
                {
                    "type": "tool_result",
                    "tool_use_id": tool_use_id,
                    "content": [{"type": "text", "text": json.dumps(result_obj)}],
                }
            ],
        }
    )


def invoke_agent(input_text: str, max_steps: int = 3) -> Dict[str, Any]:
    """Run the deployed “starting combo” behavior:
    - Always call get_service_metadata first (forced tool use)
    - Then produce a structured policy decision JSON
    """

    _require_anthropic_key()

    if not isinstance(input_text, str) or not input_text.strip():
        raise ValueError("input must be a non-empty string")
    if max_steps < 1:
        raise ValueError("max_steps must be >= 1")

    client = Anthropic()

    # We keep messages for context; tool_result blocks are embedded in "user" messages.
    messages: List[Dict[str, Any]] = [{"role": "user", "content": input_text}]

    tool_results: List[Dict[str, Any]] = []

    # Step 1: force get_service_metadata tool call.
    response1 = client.messages.create(
        model=ANTHROPIC_MODEL,
        max_tokens=ANTHROPIC_MAX_TOKENS,
        temperature=ANTHROPIC_TEMPERATURE,
        messages=messages,
        tools=TOOLS,
        tool_choice={"type": "tool", "name": "get_service_metadata"},
    )

    content1 = list(getattr(response1, "content", []) or [])
    messages.append({"role": getattr(response1, "role", "assistant"), "content": content1})

    tool_use = _find_tool_use(content1, "get_service_metadata")
    if tool_use is None:
        # Fallback: still return whatever text we got plus tool trace.
        return {"output": _extract_text(content1), "tool_results": tool_results}

    metadata = get_service_metadata()
    _append_tool_result(messages=messages, tool_results=tool_results, tool_use=tool_use, result_obj=metadata)

    # Step 2: ask the model for a policy decision JSON, using the metadata tool result.
    response2 = client.messages.create(
        model=ANTHROPIC_MODEL,
        max_tokens=ANTHROPIC_MAX_TOKENS,
        temperature=ANTHROPIC_TEMPERATURE,
        system=POLICY_SYSTEM_PROMPT,
        messages=messages,
        tools=TOOLS,
    )

    content2 = list(getattr(response2, "content", []) or [])
    messages.append({"role": getattr(response2, "role", "assistant"), "content": content2})

    output = _extract_text(content2)
    if not output:
        output = "{}"

    return {"output": output, "tool_results": tool_results}

