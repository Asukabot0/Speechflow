#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV_DIR="${ROOT_DIR}/.venv"
INSTALL_PYTHON_DEPS=1
PULL_OLLAMA_MODEL=1
OLLAMA_MODELS=("${SPEECHFLOW_BOOTSTRAP_OLLAMA_MODELS:-qwen3.5:0.8b}")

print_usage() {
  cat <<'EOF'
Usage:
  ./Scripts/install_dev_dependencies.sh [options]

Options:
  --venv <path>            Python virtualenv path (default: ./.venv)
  --no-python-deps         Skip Python ASR dependency installation
  --no-ollama-model-pull   Skip ollama pull
  -h, --help               Show this help

Environment:
  SPEECHFLOW_BOOTSTRAP_OLLAMA_MODELS
    Comma-separated models to pull.
    Example: qwen3.5:0.8b,qwen3.5:2b
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --venv)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --venv"
        exit 1
      fi
      VENV_DIR="$2"
      shift 2
      ;;
    --no-python-deps)
      INSTALL_PYTHON_DEPS=0
      shift
      ;;
    --no-ollama-model-pull)
      PULL_OLLAMA_MODEL=0
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      print_usage
      exit 1
      ;;
  esac
done

if [[ "${SPEECHFLOW_BOOTSTRAP_OLLAMA_MODELS:-}" == *","* ]]; then
  IFS=',' read -rA OLLAMA_MODELS <<< "${SPEECHFLOW_BOOTSTRAP_OLLAMA_MODELS}"
fi

require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd"
    if [[ -n "$hint" ]]; then
      echo "$hint"
    fi
    exit 1
  fi
}

brew_install_if_missing() {
  local formula="$1"
  if brew list --formula "$formula" >/dev/null 2>&1; then
    echo "[ok] brew formula already installed: $formula"
    return
  fi
  echo "[install] brew install $formula"
  brew install "$formula"
}

wait_for_ollama() {
  local wait_seconds=1
  local endpoint="${SPEECHFLOW_OLLAMA_BASE_URL:-http://127.0.0.1:11434}"
  local tags_url="${endpoint%/}/api/tags"

  for _ in {1..20}; do
    if curl -fsS "$tags_url" >/dev/null 2>&1; then
      echo "[ok] ollama endpoint ready: $tags_url"
      return
    fi
    sleep "$wait_seconds"
  done

  echo "Failed to reach Ollama endpoint: $tags_url"
  echo "Try starting it manually: ollama serve"
  exit 1
}

start_ollama() {
  local endpoint="${SPEECHFLOW_OLLAMA_BASE_URL:-http://127.0.0.1:11434}"
  local tags_url="${endpoint%/}/api/tags"

  if brew services list | grep -q '^ollama[[:space:]]'; then
    brew services start ollama >/dev/null || true
  fi

  if ! curl -fsS "$tags_url" >/dev/null 2>&1; then
    if ! pgrep -f "ollama serve" >/dev/null 2>&1; then
      nohup ollama serve >/tmp/speechflow_ollama_bootstrap.log 2>&1 &
      sleep 1
    fi
  fi
}

echo "==> Checking Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required but not installed."
  echo "Install Homebrew first: https://brew.sh/"
  exit 1
fi

echo "==> Installing base dependencies"
brew_install_if_missing python
brew_install_if_missing ollama
brew_install_if_missing ffmpeg

echo "==> Verifying required commands"
require_cmd python3 "Install via Homebrew: brew install python"
require_cmd ollama "Install via Homebrew: brew install ollama"
require_cmd curl

if [[ "$INSTALL_PYTHON_DEPS" -eq 1 ]]; then
  echo "==> Setting up Python virtualenv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  python -m pip install --upgrade pip setuptools wheel
  python -m pip install --upgrade qwen-asr faster-whisper
  deactivate

  cat <<EOF
[ok] Python dependencies installed.
To force Speechflow to use this Python runtime:
  export SPEECHFLOW_FASTER_WHISPER_PYTHON_PATH="$VENV_DIR/bin/python"
EOF
fi

echo "==> Starting Ollama service"
start_ollama
wait_for_ollama

if [[ "$PULL_OLLAMA_MODEL" -eq 1 ]]; then
  echo "==> Pulling Ollama model(s)"
  for model in "${OLLAMA_MODELS[@]}"; do
    model="$(echo "$model" | xargs)"
    if [[ -z "$model" ]]; then
      continue
    fi
    echo "[pull] ollama pull $model"
    ollama pull "$model"
  done
fi

cat <<'EOF'

==> Done
Recommended next steps:
  1) export SPEECHFLOW_FASTER_WHISPER_PYTHON_PATH="<repo>/.venv/bin/python"
  2) ./Scripts/build_dev_app_bundle.sh
  3) open dist/Speechflow.app
EOF
