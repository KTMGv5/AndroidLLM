#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
# =========================
# Termux Ollama Setup Script
# =========================

SMALL_MODEL="${SMALL_MODEL:-gemma3:270m}"
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
START_AT_END="${START_AT_END:-1}"
LOG_FILE="${LOG_FILE:-$HOME/ollama-serve.log}"
OLLAMA_PID=""   # always declared; populated only if we start the server

# ---------- helpers ----------
log()  { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[x]\033[0m %s\n" "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }
}

is_termux() {
  [[ -n "${PREFIX:-}" && "${PREFIX}" == */com.termux/* ]]
}

server_running() {
  curl -fsS "${OLLAMA_HOST}/api/version" >/dev/null 2>&1
}

start_server_bg() {
  log "Starting Ollama server (background) on ${OLLAMA_HOST} ..."
  log "Logs → ${LOG_FILE}"
  export OLLAMA_HOST
  nohup ollama serve >"$LOG_FILE" 2>&1 &
  OLLAMA_PID=$!

  for i in {1..30}; do
    # Bail early if the process died instead of spinning for 30 s
    if ! kill -0 "$OLLAMA_PID" 2>/dev/null; then
      err "ollama serve exited unexpectedly. Check logs: $LOG_FILE"
      return 1
    fi
    if server_running; then
      log "Ollama server is up. (pid=${OLLAMA_PID})"
      return 0
    fi
    sleep 1
  done

  err "Ollama server did not become ready within 30 s. Check logs: $LOG_FILE"
  return 1
}

stop_server_bg() {
  if [[ -n "$OLLAMA_PID" ]] && kill -0 "$OLLAMA_PID" 2>/dev/null; then
    log "Stopping background Ollama server (pid=${OLLAMA_PID}) ..."
    kill "$OLLAMA_PID" 2>/dev/null || true
  fi
}

cleanup() {
  [[ "${START_AT_END}" == "0" ]] && stop_server_bg
}
trap cleanup EXIT
trap 'err "Interrupted."; exit 130' INT

# ---------- sanity checks ----------
if ! is_termux; then
  warn "This script is intended for Termux. Continuing anyway..."
fi
need_cmd pkg

# ---------- 1) Install packages (idempotent) ----------
log "Updating package lists..."
pkg update -y

for pkg_name in curl ollama; do
  if pkg list-installed 2>/dev/null | grep -q "^${pkg_name}/"; then
    log "${pkg_name} already installed, skipping."
  else
    log "Installing ${pkg_name}..."
    if ! pkg install -y "$pkg_name"; then
      err "Failed to install '${pkg_name}'."
      [[ "$pkg_name" == "ollama" ]] && err "Your repo may not provide it — a manual build may be needed."
      exit 1
    fi
  fi
done

need_cmd ollama
need_cmd curl
log "Dependencies ready."

# ---------- 2) Ensure server is running ----------
export OLLAMA_HOST
if server_running; then
  log "Ollama server already running at ${OLLAMA_HOST}."
else
  start_server_bg
fi

# ---------- 3) Pull model (with retries) ----------
log "Pulling model: ${SMALL_MODEL}  (this may take a while on a slow connection)"
pull_ok=0
for attempt in 1 2 3; do
  if ollama pull "${SMALL_MODEL}"; then
    pull_ok=1
    break
  fi
  warn "Pull attempt ${attempt}/3 failed. Retrying in 5 s..."
  sleep 5
done

if [[ "$pull_ok" -eq 0 ]]; then
  err "Failed to pull model '${SMALL_MODEL}' after 3 attempts."
  err "Check server logs: ${LOG_FILE}"
  exit 1
fi
log "Model '${SMALL_MODEL}' downloaded."

# ---------- 4) Smoke test ----------
log "Running quick smoke test..."
if ollama run "${SMALL_MODEL}" "respond with only the word ok" --nowordwrap 2>/dev/null \
    | grep -qi "ok"; then
  log "Smoke test passed."
else
  warn "Smoke test returned unexpected output — model may still work, but double-check."
fi

# ---------- 5) Summary ----------
echo
echo "----------------------------------------"
log "Setup complete."
echo "----------------------------------------"
echo "Model:          ${SMALL_MODEL}"
echo "Host:           ${OLLAMA_HOST}"
echo "Server log:     ${LOG_FILE}"
echo "Server PID:     ${OLLAMA_PID:-already running (not managed by this script)}"
echo "----------------------------------------"
echo

if [[ "${START_AT_END}" == "1" ]]; then
  if ! server_running; then
    start_server_bg
  fi
  log "Leaving Ollama server running."
  echo "Try it:"
  echo "  ollama run ${SMALL_MODEL}"
else
  log "Server will be stopped on exit (START_AT_END=0)."
  echo "To start later:   ollama serve"
  echo "To run:           ollama run ${SMALL_MODEL}"
fi