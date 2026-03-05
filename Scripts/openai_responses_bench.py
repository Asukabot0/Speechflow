#!/usr/bin/env python3

import argparse
import json
import os
import pathlib
import re
import statistics
import sys
import time
import urllib.error
import urllib.request


DEFAULT_MODEL = "codex-mini-latest"
DEFAULT_API_BASE_URL = "https://api.openai.com/v1"
DEFAULT_CODEX_OAUTH_BASE_URL = "https://chatgpt.com/backend-api/codex"
DEFAULT_TIMEOUT_SECONDS = 30.0
DEFAULT_RUNS = 3
DEFAULT_MAX_OUTPUT_TOKENS = 180

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SYSTEM_PROMPT_PATH = REPO_ROOT / "Docs" / "STUDENT_TESTER_BILINGUAL_SYSTEM_PROMPT.txt"
DEFAULT_PAYLOAD_PATH = REPO_ROOT / "Docs" / "STUDENT_TESTER_BILINGUAL_SAMPLE_INPUT.json"
DEFAULT_SYSTEM_PROMPT = """You are a real-time bilingual response post-processor for spoken interactions.

You must do exactly these three things:
1. Refine the draft translation so it sounds natural, concise, and spoken, while preserving the original meaning.
2. Detect whether the speaker is asking a question, raising an issue, making a request, or expecting a response.
3. If a response is needed, generate a suggested reply in the tone of a student answering a tester or examiner.

Hard rules:
- Only use the provided source text, draft translation, recent context, and optional knowledge context.
- Do not invent product facts, policies, pricing, timelines, permissions, or troubleshooting steps.
- If the information is insufficient, the suggested reply must become a clarification-style answer instead of guessing.
- The refined translation must stay faithful to the source and must not add promises, claims, or omitted constraints.
- The suggested reply must be bilingual in Chinese and English, with aligned meaning.
- Chinese should be natural and spoken.
- English should be natural and spoken.
- Keep both language versions consistent in intent, tone, and caution level.
- Output must be strict JSON only. No markdown, no explanation, no extra text.

Tone for the suggested reply:
- Sound like a student responding to a tester, examiner, or evaluator.
- Be polite, calm, and natural.
- Show understanding first, then give a conclusion.
- Prefer cautious phrasing over absolute statements.
- It is acceptable to say things like:
  "Based on my understanding,"
  "From the information here,"
  "If I understand correctly,"
  "I may need to confirm one point first."
- Do not sound like customer support, sales, or scripted service staff.
- Do not be overly flattering, emotional, or defensive.
- Keep the response short, spoken, and practical.
- If uncertain, clearly say the information is not enough and ask for the key missing detail.

Output JSON schema:
{
  "polished_translation": "string",
  "has_question": true,
  "question_summary": "string",
  "intent": "question|bug_report|request|complaint|statement|unclear",
  "suggested_reply_zh": "string",
  "suggested_reply_en": "string",
  "reply_type": "direct_answer|clarify|acknowledge|none",
  "confidence": 0.0,
  "needs_human_review": false
}"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Minimal Responses API benchmark for latency and token throughput."
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"Model to benchmark (default: {DEFAULT_MODEL})",
    )
    parser.add_argument(
        "--base-url",
        default=None,
        help=(
            "Override the base URL. Defaults to api.openai.com for real API keys, "
            "or chatgpt.com/backend-api/codex for Codex ChatGPT OAuth."
        ),
    )
    parser.add_argument(
        "--api-key",
        default=None,
        help="Explicit API key. If omitted, OPENAI_API_KEY or ~/.codex/auth.json is used.",
    )
    parser.add_argument(
        "--auth-source",
        choices=("auto", "env", "codex"),
        default="auto",
        help="Where to resolve credentials from (default: auto).",
    )
    parser.add_argument(
        "--payload-file",
        default=str(DEFAULT_PAYLOAD_PATH),
        help="Path to a JSON file matching the prompt input schema.",
    )
    parser.add_argument(
        "--system-prompt-file",
        default=str(DEFAULT_SYSTEM_PROMPT_PATH),
        help="Text file to use as the system prompt.",
    )
    parser.add_argument(
        "--runs",
        type=int,
        default=DEFAULT_RUNS,
        help=f"Number of benchmark runs (default: {DEFAULT_RUNS})",
    )
    parser.add_argument(
        "--max-output-tokens",
        type=int,
        default=DEFAULT_MAX_OUTPUT_TOKENS,
        help=f"max_output_tokens for each request (default: {DEFAULT_MAX_OUTPUT_TOKENS})",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
        help=f"HTTP timeout in seconds (default: {DEFAULT_TIMEOUT_SECONDS})",
    )
    parser.add_argument(
        "--reasoning-effort",
        choices=("minimal", "none", "low", "medium", "high", "xhigh"),
        default=None,
        help="Optional reasoning effort to request when the backend supports it.",
    )
    parser.add_argument(
        "--skip-input-token-check",
        action="store_true",
        help="Skip the /responses/input_tokens preflight call.",
    )
    parser.add_argument(
        "--dump-response",
        action="store_true",
        help="Print the raw output text returned by the model for each run.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate config and show the prepared request without sending it.",
    )
    return parser.parse_args()


def non_empty_string(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    return stripped or None


def load_codex_config_model() -> str | None:
    config_path = pathlib.Path.home() / ".codex" / "config.toml"
    if not config_path.exists():
        return None

    try:
        content = config_path.read_text(encoding="utf-8")
    except OSError:
        return None

    match = re.search(r'(?m)^\s*model\s*=\s*"([^"]+)"\s*$', content)
    if not match:
        return None

    model = match.group(1).strip()
    return model or None


def load_auth(explicit_key: str | None, auth_source: str) -> tuple[str, str, str]:
    if explicit_key:
        cleaned = explicit_key.strip()
        if not cleaned:
            raise RuntimeError("--api-key was provided but empty.")
        return cleaned, "explicit", "api_key"

    if auth_source in ("auto", "env"):
        env_key = non_empty_string(os.environ.get("OPENAI_API_KEY"))
        if env_key:
            return env_key, "env", "api_key"
        if auth_source == "env":
            raise RuntimeError("OPENAI_API_KEY is not set.")

    if auth_source in ("auto", "codex"):
        auth_path = pathlib.Path.home() / ".codex" / "auth.json"
        if not auth_path.exists():
            if auth_source == "codex":
                raise RuntimeError(f"Codex auth file not found: {auth_path}")
        else:
            with auth_path.open("r", encoding="utf-8") as handle:
                auth_payload = json.load(handle)
            api_key = non_empty_string(auth_payload.get("OPENAI_API_KEY"))
            if api_key:
                return api_key, "codex", "api_key"

            auth_mode = non_empty_string(auth_payload.get("auth_mode"))
            tokens = auth_payload.get("tokens")
            if isinstance(tokens, dict):
                access_token = non_empty_string(tokens.get("access_token"))
                if access_token and auth_mode == "chatgpt":
                    return access_token, "codex", "oauth_access_token"

            if auth_source == "codex":
                raise RuntimeError(
                    f"{auth_path} does not contain a usable API key or ChatGPT access token. Run `codex login` first."
                )

    raise RuntimeError(
        "No usable credentials found. Pass --api-key, set OPENAI_API_KEY, or log in with `codex login`."
    )


def resolve_base_url(explicit_base_url: str | None, credential_kind: str) -> str:
    if explicit_base_url:
        return explicit_base_url

    if credential_kind == "oauth_access_token":
        return DEFAULT_CODEX_OAUTH_BASE_URL

    return DEFAULT_API_BASE_URL


def resolve_model(requested_model: str | None, credential_kind: str) -> str:
    explicit_model = non_empty_string(requested_model)
    if explicit_model and explicit_model != DEFAULT_MODEL:
        return explicit_model

    if credential_kind == "oauth_access_token":
        return load_codex_config_model() or "gpt-5.3-codex"

    return explicit_model or DEFAULT_MODEL


def load_payload(payload_path: str) -> dict:
    path = pathlib.Path(payload_path).expanduser()
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_system_prompt(prompt_path: str | None) -> str:
    if not prompt_path:
        return DEFAULT_SYSTEM_PROMPT

    path = pathlib.Path(prompt_path).expanduser()
    if not path.exists():
        return DEFAULT_SYSTEM_PROMPT
    with path.open("r", encoding="utf-8") as handle:
        return handle.read().strip()


def build_input_text(input_payload: dict) -> str:
    return json.dumps(input_payload, ensure_ascii=False, separators=(",", ":"))


def post_json(
    *,
    url: str,
    api_key: str,
    payload: dict,
    timeout_seconds: float,
) -> dict:
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url=url, data=body, method="POST")
    request.add_header("Authorization", f"Bearer {api_key}")
    request.add_header("Content-Type", "application/json")

    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(
            f"HTTP {error.code} from {url}: {detail[:800]}"
        ) from error
    except urllib.error.URLError as error:
        raise RuntimeError(f"Request failed for {url}: {error}") from error


def build_request(url: str, api_key: str, payload: dict, accept: str | None = None) -> urllib.request.Request:
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url=url, data=body, method="POST")
    request.add_header("Authorization", f"Bearer {api_key}")
    request.add_header("Content-Type", "application/json")
    if accept:
        request.add_header("Accept", accept)
    return request


def parse_sse_data(block_lines: list[str]) -> str | None:
    data_parts: list[str] = []
    for raw_line in block_lines:
        line = raw_line.strip("\r")
        if not line or line.startswith(":"):
            continue
        if line.startswith("data:"):
            data_parts.append(line[5:].lstrip())
    if not data_parts:
        return None
    return "\n".join(data_parts)


def estimate_input_tokens(
    *,
    base_url: str,
    api_key: str,
    model: str,
    system_prompt: str,
    messages: list[dict],
    timeout_seconds: float,
) -> int | None:
    url = base_url.rstrip("/") + "/responses/input_tokens"
    payload = {
        "model": model,
        "instructions": system_prompt,
        "input": messages,
        "store": False,
    }
    result = post_json(
        url=url,
        api_key=api_key,
        payload=payload,
        timeout_seconds=timeout_seconds,
    )

    if isinstance(result, dict):
        if isinstance(result.get("input_tokens"), int):
            return result["input_tokens"]
        usage = result.get("usage")
        if isinstance(usage, dict) and isinstance(usage.get("input_tokens"), int):
            return usage["input_tokens"]
    return None


def create_response(
    *,
    base_url: str,
    api_key: str,
    credential_kind: str,
    model: str,
    system_prompt: str,
    messages: list[dict],
    max_output_tokens: int,
    reasoning_effort: str | None,
    timeout_seconds: float,
) -> tuple[dict, float, float | None]:
    url = base_url.rstrip("/") + "/responses"
    payload = {
        "model": model,
        "instructions": system_prompt,
        "input": messages,
        "store": False,
        "stream": True,
    }
    if credential_kind != "oauth_access_token":
        payload["max_output_tokens"] = max_output_tokens
    if reasoning_effort:
        payload["reasoning"] = {"effort": reasoning_effort}
    started = time.perf_counter()
    request = build_request(
        url=url,
        api_key=api_key,
        payload=payload,
        accept="text/event-stream",
    )

    ttfb_seconds: float | None = None
    output_fragments: list[str] = []
    final_response: dict = {}
    pending_block: list[str] = []

    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            while True:
                raw_line = response.readline()
                if raw_line == b"":
                    break

                line = raw_line.decode("utf-8", errors="replace")
                if line in ("\n", "\r\n"):
                    if not pending_block:
                        continue

                    data = parse_sse_data(pending_block)
                    pending_block = []
                    if data is None:
                        continue
                    if data == "[DONE]":
                        break

                    try:
                        event = json.loads(data)
                    except json.JSONDecodeError:
                        continue

                    if not isinstance(event, dict):
                        continue

                    event_type = event.get("type")

                    if event_type == "response.output_text.delta":
                        delta = event.get("delta")
                        if isinstance(delta, str) and delta:
                            if ttfb_seconds is None:
                                ttfb_seconds = time.perf_counter() - started
                            output_fragments.append(delta)
                        continue

                    if event_type == "response.output_text.done":
                        if not output_fragments:
                            text = event.get("text")
                            if isinstance(text, str) and text:
                                if ttfb_seconds is None:
                                    ttfb_seconds = time.perf_counter() - started
                                output_fragments.append(text)
                        continue

                    if event_type in ("response.completed", "response.failed", "response.incomplete"):
                        response_payload = event.get("response")
                        if isinstance(response_payload, dict):
                            final_response = response_payload

                        if event_type != "response.completed":
                            error_detail = event.get("error") or event.get("detail") or event
                            raise RuntimeError(f"Streaming response ended with {event_type}: {error_detail}")
                        continue

                    if event_type == "error":
                        raise RuntimeError(f"Streaming error event: {event}")

                else:
                    pending_block.append(line)
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(
            f"HTTP {error.code} from {url}: {detail[:800]}"
        ) from error
    except urllib.error.URLError as error:
        raise RuntimeError(f"Request failed for {url}: {error}") from error

    if pending_block:
        data = parse_sse_data(pending_block)
        if data and data != "[DONE]":
            try:
                event = json.loads(data)
            except json.JSONDecodeError:
                event = None
            if isinstance(event, dict):
                response_payload = event.get("response")
                if isinstance(response_payload, dict):
                    final_response = response_payload

    if output_fragments:
        final_response["output_text"] = "".join(output_fragments).strip()

    elapsed_seconds = time.perf_counter() - started
    return final_response, elapsed_seconds, ttfb_seconds


def extract_output_text(response_payload: dict) -> str:
    output_text = response_payload.get("output_text")
    if isinstance(output_text, str) and output_text.strip():
        return output_text.strip()

    output_items = response_payload.get("output")
    if not isinstance(output_items, list):
        return ""

    fragments: list[str] = []
    for item in output_items:
        if not isinstance(item, dict):
            continue
        contents = item.get("content")
        if not isinstance(contents, list):
            continue
        for content_item in contents:
            if not isinstance(content_item, dict):
                continue
            text = content_item.get("text")
            if isinstance(text, str) and text:
                fragments.append(text)

    return "\n".join(fragment for fragment in fragments if fragment).strip()


def extract_usage(response_payload: dict) -> tuple[int | None, int | None, int | None]:
    usage = response_payload.get("usage")
    if not isinstance(usage, dict):
        return None, None, None

    input_tokens = usage.get("input_tokens")
    output_tokens = usage.get("output_tokens")
    total_tokens = usage.get("total_tokens")

    return (
        input_tokens if isinstance(input_tokens, int) else None,
        output_tokens if isinstance(output_tokens, int) else None,
        total_tokens if isinstance(total_tokens, int) else None,
    )


def format_float(value: float | None, digits: int = 2) -> str:
    if value is None:
        return "n/a"
    return f"{value:.{digits}f}"


def main() -> int:
    args = parse_args()

    if args.runs < 1:
        print("--runs must be at least 1", file=sys.stderr)
        return 2

    try:
        credential, auth_source_name, credential_kind = load_auth(args.api_key, args.auth_source)
        base_url = resolve_base_url(args.base_url, credential_kind)
        model = resolve_model(args.model, credential_kind)
        input_payload = load_payload(args.payload_file)
        system_prompt = load_system_prompt(args.system_prompt_file)
    except Exception as error:
        print(f"Setup failed: {error}", file=sys.stderr)
        return 1

    input_text = build_input_text(input_payload)
    messages = [
        {
            "role": "user",
            "content": [{"type": "input_text", "text": input_text}],
        }
    ]
    prepared_request = {
        "model": model,
        "instructions": system_prompt,
        "input": messages,
        "store": False,
    }
    if credential_kind != "oauth_access_token":
        prepared_request["max_output_tokens"] = args.max_output_tokens
    if args.reasoning_effort:
        prepared_request["reasoning"] = {"effort": args.reasoning_effort}

    if args.dry_run:
        preview = {
            "auth_source": auth_source_name,
            "credential_kind": credential_kind,
            "model": model,
            "runs": args.runs,
            "base_url": base_url,
            "payload_file": str(pathlib.Path(args.payload_file).expanduser()),
            "system_prompt_chars": len(system_prompt),
            "user_payload_chars": len(input_text),
            "request_preview": prepared_request,
        }
        print(json.dumps(preview, indent=2, ensure_ascii=False))
        return 0

    estimated_input_tokens = None
    should_skip_input_token_check = args.skip_input_token_check or credential_kind == "oauth_access_token"

    if not should_skip_input_token_check:
        try:
            estimated_input_tokens = estimate_input_tokens(
                base_url=base_url,
                api_key=credential,
                model=model,
                system_prompt=system_prompt,
                messages=messages,
                timeout_seconds=args.timeout,
            )
        except Exception as error:
            print(f"Input token preflight skipped after failure: {error}", file=sys.stderr)

    run_latencies_ms: list[float] = []
    run_ttfb_ms: list[float] = []
    run_output_tps: list[float] = []
    run_total_tps: list[float] = []
    run_generation_output_tps: list[float] = []

    print(f"Model: {model}")
    print(f"Auth source: {auth_source_name}")
    print(f"Credential kind: {credential_kind}")
    print(f"Base URL: {base_url}")
    print(f"Runs: {args.runs}")
    if credential_kind == "oauth_access_token" and not args.skip_input_token_check:
        print("Estimated input tokens (preflight): skipped for Codex OAuth transport")
    else:
        print(f"Estimated input tokens (preflight): {estimated_input_tokens if estimated_input_tokens is not None else 'n/a'}")
    print("")

    for run_index in range(1, args.runs + 1):
        try:
            response_payload, elapsed_seconds, ttfb_seconds = create_response(
                base_url=base_url,
                api_key=credential,
                credential_kind=credential_kind,
                model=model,
                system_prompt=system_prompt,
                messages=messages,
                max_output_tokens=args.max_output_tokens,
                reasoning_effort=args.reasoning_effort,
                timeout_seconds=args.timeout,
            )
        except Exception as error:
            print(f"Run {run_index}: FAILED: {error}", file=sys.stderr)
            return 1

        input_tokens, output_tokens, total_tokens = extract_usage(response_payload)
        output_text = extract_output_text(response_payload)
        latency_ms = elapsed_seconds * 1000.0
        ttfb_ms = (ttfb_seconds * 1000.0) if ttfb_seconds is not None else None
        output_tps = (
            (output_tokens / elapsed_seconds)
            if output_tokens is not None and elapsed_seconds > 0
            else None
        )
        total_tps = (
            (total_tokens / elapsed_seconds)
            if total_tokens is not None and elapsed_seconds > 0
            else None
        )
        generation_output_tps = (
            (output_tokens / max(elapsed_seconds - ttfb_seconds, 0.001))
            if output_tokens is not None and ttfb_seconds is not None and elapsed_seconds > ttfb_seconds
            else None
        )

        run_latencies_ms.append(latency_ms)
        if ttfb_ms is not None:
            run_ttfb_ms.append(ttfb_ms)
        if output_tps is not None:
            run_output_tps.append(output_tps)
        if total_tps is not None:
            run_total_tps.append(total_tps)
        if generation_output_tps is not None:
            run_generation_output_tps.append(generation_output_tps)

        print(
            "Run {run}: latency={latency} ms ttfb={ttfb} ms input_tokens={in_tok} output_tokens={out_tok} "
            "total_tokens={total_tok} output_tps={out_tps} generation_output_tps={gen_out_tps} total_tps={total_tps}".format(
                run=run_index,
                latency=format_float(latency_ms),
                ttfb=format_float(ttfb_ms),
                in_tok=input_tokens if input_tokens is not None else "n/a",
                out_tok=output_tokens if output_tokens is not None else "n/a",
                total_tok=total_tokens if total_tokens is not None else "n/a",
                out_tps=format_float(output_tps),
                gen_out_tps=format_float(generation_output_tps),
                total_tps=format_float(total_tps),
            )
        )

        if args.dump_response:
            print("Response:")
            print(output_text)
            print("")

    print("")
    print(
        "Summary: avg_latency={avg} ms min_latency={minv} ms max_latency={maxv} ms".format(
            avg=format_float(statistics.mean(run_latencies_ms)),
            minv=format_float(min(run_latencies_ms)),
            maxv=format_float(max(run_latencies_ms)),
        )
    )
    if run_ttfb_ms:
        print(f"Summary: avg_ttfb={format_float(statistics.mean(run_ttfb_ms))} ms")

    if run_output_tps:
        print(f"Summary: avg_output_tps={format_float(statistics.mean(run_output_tps))}")
    if run_generation_output_tps:
        print(f"Summary: avg_generation_output_tps={format_float(statistics.mean(run_generation_output_tps))}")
    if run_total_tps:
        print(f"Summary: avg_total_tps={format_float(statistics.mean(run_total_tps))}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
