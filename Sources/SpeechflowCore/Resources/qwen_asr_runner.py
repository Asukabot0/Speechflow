#!/usr/bin/env python3

import json
import os
import platform
import sys

DEFAULT_MODEL = "mlx-community/Qwen3-ASR-1.7B-4bit"
COMPUTE_TYPE = "4bit"
DEFAULT_WARMUP_LANGUAGE = "English"


def _env_int(key: str, default: int) -> int:
    raw = os.environ.get(key)
    if raw is None:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def _emit(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _env_model() -> str:
    for key in ("SPEECHFLOW_ASR_MODEL_PATH", "SPEECHFLOW_ASR_MODEL"):
        value = os.environ.get(key, "").strip()
        if value:
            return value
    return DEFAULT_MODEL


def _verify_mlx_environment(mx):
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise RuntimeError(
            "MLX ASR requires macOS on Apple Silicon. Speechflow will fall back to system speech recognition."
        )
    if not mx.metal.is_available():
        raise RuntimeError(
            "MLX / Metal is unavailable. Speechflow will fall back to system speech recognition."
        )


def _load_model():
    try:
        import mlx.core as mx
        from mlx_audio.stt import load_model
    except Exception as exc:
        raise RuntimeError(
            "mlx-audio is not installed or failed to import. "
            "Run ./Scripts/install_dev_dependencies.sh or install requirements.txt."
        ) from exc

    import numpy as np

    _verify_mlx_environment(mx)

    model_ref = _env_model()
    max_tokens = _env_int("SPEECHFLOW_ASR_MAX_NEW_TOKENS", 512)

    model = load_model(model_ref)
    model_device = str(mx.default_device())

    # Warm up on silence so model and device errors happen during startup.
    silence = np.zeros(16000, dtype=np.float32)
    model.generate(
        silence,
        language=DEFAULT_WARMUP_LANGUAGE,
        max_tokens=min(max_tokens, 8),
        verbose=False,
    )

    return model_ref, model, model_device, max_tokens


def _normalize_language(language: str | None):
    if language is None:
        return None

    normalized = language.strip()
    if not normalized:
        return None

    return normalized


def _segment_texts(transcription):
    raw_segments = getattr(transcription, "segments", None) or []
    texts = []
    for segment in raw_segments:
        if isinstance(segment, dict):
            text = segment.get("text", "")
        else:
            text = getattr(segment, "text", "")
        normalized = (text or "").strip()
        if normalized:
            texts.append(normalized)
    return texts


def _transcribe(model, max_tokens: int, request):
    language = _normalize_language(request.get("language"))
    generate_kwargs = {
        "audio": request["audio_path"],
        "max_tokens": max_tokens,
        "verbose": False,
    }
    if language is not None:
        generate_kwargs["language"] = language
    transcription = model.generate(**generate_kwargs)

    text = (getattr(transcription, "text", "") or "").strip()
    segments = _segment_texts(transcription)
    return {
        "text": text,
        "segments": segments if segments else ([text] if text else []),
        "language": getattr(transcription, "language", None),
    }


def main():
    try:
        model_ref, model, model_device, max_tokens = _load_model()
    except Exception as exc:
        _emit({"type": "startup_error", "message": str(exc)})
        return 1

    _emit(
        {
            "type": "ready",
            "model": model_ref,
            "device": model_device,
            "compute_type": COMPUTE_TYPE,
            "backend": "mlx_audio",
        }
    )

    for raw_line in sys.stdin:
        raw_line = raw_line.strip()
        if not raw_line:
            continue

        try:
            request = json.loads(raw_line)
        except Exception as exc:
            _emit({"type": "error", "message": f"Invalid request: {exc}"})
            continue

        if request.get("type") == "shutdown":
            return 0

        if request.get("type") != "transcribe":
            _emit({"type": "error", "message": "Unsupported request type."})
            continue

        try:
            response = _transcribe(model, max_tokens, request)
            _emit({"type": "result", "ok": True, **response})
        except Exception as exc:
            _emit({"type": "error", "message": str(exc)})

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
