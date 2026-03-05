#!/usr/bin/env python3

import json
import os
import sys

QWEN3_ASR_DEFAULT_MODEL = "Qwen/Qwen3-ASR-1.7B"


def _env_str(key: str, default: str = "") -> str:
    value = os.environ.get(key)
    if value is None:
        return default
    return value


def _env_int(key: str, default: int) -> int:
    raw = os.environ.get(key)
    if raw is None:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def _env_float(key: str, default: float) -> float:
    raw = os.environ.get(key)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def _env_optional_float(key: str):
    raw = os.environ.get(key)
    if raw is None or raw == "":
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def _emit(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _coalesce_str(*values: str, default: str = "") -> str:
    for value in values:
        if value is None:
            continue
        stripped = value.strip()
        if stripped:
            return stripped
    return default


def _env_model_name() -> str:
    return _coalesce_str(
        os.environ.get("SPEECHFLOW_ASR_MODEL"),
        os.environ.get("SPEECHFLOW_FASTER_WHISPER_MODEL"),
        default=QWEN3_ASR_DEFAULT_MODEL,
    )


def _env_model_path() -> str:
    return _coalesce_str(
        os.environ.get("SPEECHFLOW_ASR_MODEL_PATH"),
        os.environ.get("SPEECHFLOW_FASTER_WHISPER_MODEL_PATH"),
    )


def _env_download_root():
    value = _coalesce_str(
        os.environ.get("SPEECHFLOW_ASR_DOWNLOAD_ROOT"),
        os.environ.get("SPEECHFLOW_FASTER_WHISPER_DOWNLOAD_ROOT"),
    )
    return value or None


def _env_device() -> str:
    return _coalesce_str(
        os.environ.get("SPEECHFLOW_ASR_DEVICE"),
        os.environ.get("SPEECHFLOW_FASTER_WHISPER_DEVICE"),
        default="cpu",
    )


def _env_compute_type() -> str:
    return _coalesce_str(
        os.environ.get("SPEECHFLOW_ASR_COMPUTE_TYPE"),
        os.environ.get("SPEECHFLOW_FASTER_WHISPER_COMPUTE_TYPE"),
        default="int8",
    )


def _env_local_only() -> bool:
    return _coalesce_str(
        os.environ.get("SPEECHFLOW_ASR_LOCAL_ONLY"),
        os.environ.get("SPEECHFLOW_FASTER_WHISPER_LOCAL_ONLY"),
    ).lower() in {"1", "true", "yes"}


def _env_backend() -> str:
    raw = _coalesce_str(os.environ.get("SPEECHFLOW_ASR_BACKEND")).lower()
    if raw in {"qwen", "qwen_asr", "qwen3-asr"}:
        return "qwen_asr"
    if raw in {"whisper", "faster_whisper", "faster-whisper"}:
        return "faster_whisper"
    return ""


def _resolve_backend(model_name: str, model_path: str) -> str:
    explicit_backend = _env_backend()
    if explicit_backend:
        return explicit_backend

    if model_path:
        lowered_path = model_path.lower()
        if "qwen3-asr" in lowered_path:
            return "qwen_asr"
        return "faster_whisper"

    if "qwen3-asr" in model_name.lower():
        return "qwen_asr"

    return "faster_whisper"


def _load_faster_whisper_model(model_ref, download_root, local_files_only, device, compute_type):
    from faster_whisper import WhisperModel

    cpu_threads = _env_int("SPEECHFLOW_FASTER_WHISPER_CPU_THREADS", 0)
    num_workers = _env_int("SPEECHFLOW_FASTER_WHISPER_NUM_WORKERS", 1)

    return (
        WhisperModel(
            model_ref,
            device=device,
            compute_type=compute_type,
            cpu_threads=cpu_threads,
            num_workers=num_workers,
            download_root=download_root,
            local_files_only=local_files_only,
        ),
        model_ref,
        device,
        compute_type,
    )


def _resolve_qwen_device(device: str) -> str:
    import torch

    normalized = (device or "cpu").strip().lower()
    if normalized == "auto":
        if torch.cuda.is_available():
            return "cuda:0"
        if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            return "mps"
        return "cpu"
    return device or "cpu"


def _resolve_qwen_dtype(device: str, compute_type: str):
    import torch

    normalized_compute_type = (compute_type or "").strip().lower()
    if normalized_compute_type in {"bf16", "bfloat16"}:
        return torch.bfloat16, "bfloat16"
    if normalized_compute_type in {"fp16", "float16", "half"}:
        return torch.float16, "float16"
    if normalized_compute_type in {"fp32", "float32"}:
        return torch.float32, "float32"

    normalized_device = (device or "cpu").strip().lower()
    if normalized_device.startswith("cuda"):
        return torch.bfloat16, "bfloat16"
    if normalized_device == "mps":
        return torch.float16, "float16"
    return torch.float32, "float32"


def _load_qwen_asr_model(model_ref, download_root, local_files_only, device, compute_type):
    try:
        from qwen_asr import Qwen3ASRModel
    except ImportError as exc:
        raise RuntimeError(
            "Qwen3-ASR requires the 'qwen-asr' Python package. Install it with 'pip install -U qwen-asr'."
        ) from exc

    resolved_device = _resolve_qwen_device(device)
    dtype, dtype_name = _resolve_qwen_dtype(resolved_device, compute_type)

    if download_root:
        os.environ.setdefault("HF_HOME", download_root)
    if local_files_only:
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"

    return (
        Qwen3ASRModel.from_pretrained(
            model_ref,
            dtype=dtype,
            device_map=resolved_device,
        ),
        model_ref,
        resolved_device,
        dtype_name,
    )


def _load_model():
    model_path = _env_model_path()
    model_name = _env_model_name()
    model_ref = model_path or model_name

    download_root = _env_download_root()
    local_files_only = _env_local_only()
    device = _env_device()
    compute_type = _env_compute_type()

    backend = _resolve_backend(model_name, model_path)
    if backend == "qwen_asr":
        model, model_ref, device, compute_type = _load_qwen_asr_model(
            model_ref=model_ref,
            download_root=download_root,
            local_files_only=local_files_only,
            device=device,
            compute_type=compute_type,
        )
    else:
        model, model_ref, device, compute_type = _load_faster_whisper_model(
            model_ref=model_ref,
            download_root=download_root,
            local_files_only=local_files_only,
            device=device,
            compute_type=compute_type,
        )

    return model, model_ref, device, compute_type, backend


def _transcribe_faster_whisper(model, request):
    beam_size = _env_int("SPEECHFLOW_FASTER_WHISPER_BEAM_SIZE", 5)
    best_of = _env_int("SPEECHFLOW_FASTER_WHISPER_BEST_OF", 5)
    temperature = _env_float("SPEECHFLOW_FASTER_WHISPER_TEMPERATURE", 0.0)

    vad_min_speech_ms = _env_int("SPEECHFLOW_FASTER_WHISPER_VAD_MIN_SPEECH_MS", 120)
    vad_min_silence_ms = _env_int("SPEECHFLOW_FASTER_WHISPER_VAD_MIN_SILENCE_MS", 360)
    vad_speech_pad_ms = _env_int("SPEECHFLOW_FASTER_WHISPER_VAD_SPEECH_PAD_MS", 180)

    log_prob_threshold = _env_float("SPEECHFLOW_FASTER_WHISPER_LOG_PROB_THRESHOLD", -0.8)
    no_speech_threshold = _env_float("SPEECHFLOW_FASTER_WHISPER_NO_SPEECH_THRESHOLD", 0.45)
    hallucination_silence_threshold = _env_optional_float(
        "SPEECHFLOW_FASTER_WHISPER_HALLUCINATION_SILENCE_THRESHOLD"
    )

    language = request.get("language")
    if language == "auto":
        language = None

    segments, info = model.transcribe(
        request["audio_path"],
        language=language,
        beam_size=beam_size,
        best_of=best_of,
        temperature=temperature,
        condition_on_previous_text=False,
        without_timestamps=True,
        vad_filter=True,
        vad_parameters=dict(
            min_speech_duration_ms=vad_min_speech_ms,
            min_silence_duration_ms=vad_min_silence_ms,
            speech_pad_ms=vad_speech_pad_ms,
        ),
        word_timestamps=False,
        log_prob_threshold=log_prob_threshold,
        no_speech_threshold=no_speech_threshold,
        hallucination_silence_threshold=hallucination_silence_threshold,
    )

    segments = list(segments)
    text_parts = []
    segment_texts = []
    for segment in segments:
        text = segment.text.strip()
        if text:
            text_parts.append(text)
            segment_texts.append(text)

    return {
        "text": " ".join(text_parts).strip(),
        "segments": segment_texts,
        "language": getattr(info, "language", None),
        "language_probability": getattr(info, "language_probability", None),
        "duration": getattr(info, "duration", None),
    }


def _get_value(item, key, default=None):
    if isinstance(item, dict):
        return item.get(key, default)
    return getattr(item, key, default)


def _qwen_language_name(language):
    if not language or language == "auto":
        return None

    return {
        "en": "English",
        "zh": "Chinese",
        "ja": "Japanese",
        "ko": "Korean",
        "es": "Spanish",
        "fr": "French",
        "de": "German",
    }.get(language, language)


def _extract_text_segments(value):
    if not isinstance(value, (list, tuple)):
        return []

    segments = []
    for item in value:
        if isinstance(item, str):
            text = item.strip()
        else:
            text = str(_get_value(item, "text", "")).strip()
        if text:
            segments.append(text)
    return segments


def _normalize_qwen_result(result):
    if result is None:
        return None
    if isinstance(result, (list, tuple)):
        return result[0] if result else None
    return result


def _transcribe_qwen_asr(model, request):
    result = model.transcribe(
        audio=request["audio_path"],
        language=_qwen_language_name(request.get("language")),
    )
    result = _normalize_qwen_result(result)

    text = str(_get_value(result, "text", "") or "").strip()
    segments = (
        _extract_text_segments(_get_value(result, "segments"))
        or _extract_text_segments(_get_value(result, "sentences"))
        or _extract_text_segments(_get_value(result, "chunks"))
    )

    if text and not segments:
        segments = [text]

    return {
        "text": text,
        "segments": segments,
        "language": _get_value(result, "language"),
        "language_probability": _get_value(result, "language_probability"),
        "duration": _get_value(result, "duration"),
    }


def _transcribe(model, request, backend):
    if backend == "qwen_asr":
        return _transcribe_qwen_asr(model, request)

    return _transcribe_faster_whisper(model, request)


def main():
    try:
        model, model_ref, device, compute_type, backend = _load_model()
    except Exception as exc:
        _emit({"type": "startup_error", "message": str(exc)})
        return 1

    _emit(
        {
            "type": "ready",
            "model": model_ref,
            "device": device,
            "compute_type": compute_type,
            "backend": backend,
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
            response = _transcribe(model, request, backend)
            _emit({"type": "result", "ok": True, **response})
        except Exception as exc:
            _emit({"type": "error", "message": str(exc)})

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
