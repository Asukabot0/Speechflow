#!/usr/bin/env python3

import json
import os
import sys


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


def _load_model():
    from faster_whisper import WhisperModel

    model_path = _env_str("SPEECHFLOW_FASTER_WHISPER_MODEL_PATH", "").strip()
    model_name = _env_str("SPEECHFLOW_FASTER_WHISPER_MODEL", "turbo").strip() or "turbo"
    model_ref = model_path or model_name

    download_root = _env_str("SPEECHFLOW_FASTER_WHISPER_DOWNLOAD_ROOT", "").strip() or None
    local_files_only = _env_str("SPEECHFLOW_FASTER_WHISPER_LOCAL_ONLY", "").strip() in {"1", "true", "yes"}

    device = _env_str("SPEECHFLOW_FASTER_WHISPER_DEVICE", "cpu").strip() or "cpu"
    compute_type = _env_str("SPEECHFLOW_FASTER_WHISPER_COMPUTE_TYPE", "int8").strip() or "int8"
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


def _transcribe(model, request):
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


def main():
    try:
        model, model_ref, device, compute_type = _load_model()
    except Exception as exc:
        _emit({"type": "startup_error", "message": str(exc)})
        return 1

    _emit(
        {
            "type": "ready",
            "model": model_ref,
            "device": device,
            "compute_type": compute_type,
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
            response = _transcribe(model, request)
            _emit({"type": "result", "ok": True, **response})
        except Exception as exc:
            _emit({"type": "error", "message": str(exc)})

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
