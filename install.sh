#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="${REPO_OWNER:-nirm3l}"
REPO_NAME="${REPO_NAME:-constructos}"
REPO_REF="${REPO_REF:-main}"
INSTALL_DIR="${INSTALL_DIR:-./constructos-client}"
IMAGE_TAG="${IMAGE_TAG:-}"
LICENSE_SERVER_TOKEN="${LICENSE_SERVER_TOKEN:-}"
ACTIVATION_CODE="${ACTIVATION_CODE:-}"
LICENSE_SERVER_URL="${LICENSE_SERVER_URL:-https://licence.constructos.dev}"
AUTO_DEPLOY="${AUTO_DEPLOY:-false}"
INSTALL_COS="${INSTALL_COS:-true}"
COS_INSTALL_METHOD="${COS_INSTALL_METHOD:-pipx}"
INSTALL_OLLAMA="${INSTALL_OLLAMA:-auto}"
DEPLOY_OLLAMA_MODE="${DEPLOY_OLLAMA_MODE:-}"
DEPLOY_WITH_OLLAMA="${DEPLOY_WITH_OLLAMA:-}"
CODEX_CONFIG_FILE="${CODEX_CONFIG_FILE:-}"
CODEX_AUTH_FILE="${CODEX_AUTH_FILE:-}"
EXCHANGED_IMAGE_TAG=""

LOG_COLOR_RESET=""
LOG_COLOR_INFO=""
LOG_COLOR_WARN=""
LOG_COLOR_ERROR=""

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  LOG_COLOR_RESET=$'\033[0m'
  LOG_COLOR_INFO=$'\033[1;32m'
fi

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  LOG_COLOR_WARN=$'\033[1;33m'
  LOG_COLOR_ERROR=$'\033[1;31m'
fi

log_info() {
  printf '%b%s%b\n' "$LOG_COLOR_INFO" "[INFO] $*" "$LOG_COLOR_RESET"
}

log_warn() {
  printf '%b%s%b\n' "$LOG_COLOR_WARN" "[WARN] $*" "$LOG_COLOR_RESET" >&2
}

log_error() {
  printf '%b%s%b\n' "$LOG_COLOR_ERROR" "[ERROR] $*" "$LOG_COLOR_RESET" >&2
}

is_truthy() {
  case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_truthy() {
  case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on)
      echo "true"
      ;;
    0 | false | no | off)
      echo "false"
      ;;
    auto | "")
      echo "auto"
      ;;
    *)
      echo "invalid"
      ;;
  esac
}

normalize_ollama_mode() {
  case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    auto | "")
      echo "auto"
      ;;
    docker)
      echo "docker"
      ;;
    docker-gpu)
      echo "docker-gpu"
      ;;
    host)
      echo "host"
      ;;
    none)
      echo "none"
      ;;
    1 | true | yes | on)
      echo "docker"
      ;;
    0 | false | no | off)
      echo "none"
      ;;
    *)
      echo "invalid"
      ;;
  esac
}

resolve_host_os() {
  local uname_value
  uname_value="$(uname -s 2>/dev/null || echo "unknown")"
  case "$uname_value" in
    Linux*)
      echo "linux"
      ;;
    Darwin*)
      echo "macos"
      ;;
    CYGWIN* | MINGW* | MSYS*)
      echo "windows"
      ;;
    *)
      if [[ "${OS:-}" == "Windows_NT" ]]; then
        echo "windows"
      else
        echo "unknown"
      fi
      ;;
  esac
}

docker_install_hint() {
  local host_os="$1"
  case "$host_os" in
    macos | windows)
      echo "Install Docker Desktop and start it before deploy."
      ;;
    linux)
      echo "Install Docker Engine + Docker Compose plugin and start the docker service."
      ;;
    *)
      echo "Install Docker with Compose support and ensure the daemon is running."
      ;;
  esac
}

ensure_docker_available() {
  local host_os="$1"
  local required="$2"

  if ! command -v docker >/dev/null 2>&1; then
    if [[ "$required" == "true" ]]; then
      log_error "Docker is required for deployment but was not found."
      log_error "$(docker_install_hint "$host_os")"
      exit 1
    fi
    log_warn "Docker is not installed. You must install Docker before running deploy."
    log_warn "$(docker_install_hint "$host_os")"
    return 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    if [[ "$required" == "true" ]]; then
      log_error "Docker Compose plugin is required but unavailable."
      log_error "$(docker_install_hint "$host_os")"
      exit 1
    fi
    log_warn "Docker Compose plugin is missing. Deploy will fail until it is installed."
    return 1
  fi

  if ! docker info >/dev/null 2>&1; then
    if [[ "$required" == "true" ]]; then
      log_error "Docker is installed but the daemon is not reachable."
      log_error "Start Docker and retry."
      exit 1
    fi
    log_warn "Docker daemon is not reachable right now."
    log_warn "Start Docker before running deploy."
    return 1
  fi

  return 0
}

resolve_requested_ollama_mode() {
  if [[ -z "$DEPLOY_OLLAMA_MODE" ]]; then
    DEPLOY_OLLAMA_MODE="$DEPLOY_WITH_OLLAMA"
  fi
  if [[ -z "$DEPLOY_OLLAMA_MODE" ]]; then
    DEPLOY_OLLAMA_MODE="auto"
  fi

  DEPLOY_OLLAMA_MODE="$(normalize_ollama_mode "$DEPLOY_OLLAMA_MODE")"
  if [[ "$DEPLOY_OLLAMA_MODE" == "invalid" ]]; then
    log_warn "Unsupported DEPLOY_OLLAMA_MODE value. Falling back to auto."
    DEPLOY_OLLAMA_MODE="auto"
  fi
}

upsert_env_value() {
  local file_path="$1"
  local key="$2"
  local value="$3"
  local tmp_file
  local found=0
  tmp_file="$(mktemp "${file_path}.tmp.XXXXXX")"
  if [[ -f "$file_path" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^[[:space:]]*${key}= ]]; then
        printf '%s=%s\n' "$key" "$value" >>"$tmp_file"
        found=1
      else
        printf '%s\n' "$line" >>"$tmp_file"
      fi
    done <"$file_path"
  fi
  if [[ "$found" -eq 0 ]]; then
    printf '%s=%s\n' "$key" "$value" >>"$tmp_file"
  fi
  mv "$tmp_file" "$file_path"
}

prepare_env_file() {
  local install_path="$1"
  local env_file="${install_path}/.env"
  local env_example_file="${install_path}/.env.example"
  if [[ -f "$env_file" ]]; then
    printf '%s' "$env_file"
    return 0
  fi
  if [[ -f "$env_example_file" ]]; then
    cp "$env_example_file" "$env_file"
  else
    touch "$env_file"
  fi
  printf '%s' "$env_file"
}

install_cos_cli() {
  local install_path="$1"
  local method="${COS_INSTALL_METHOD}"
  local cos_install_script="${install_path}/tools/cos/scripts/install.sh"

  if ! is_truthy "${INSTALL_COS}"; then
    log_info "Skipping COS CLI installation (INSTALL_COS=${INSTALL_COS})."
    return 0
  fi

  if [[ ! -f "${cos_install_script}" ]]; then
    log_warn "COS CLI install script not found at ${cos_install_script}; skipping."
    return 0
  fi

  if [[ "${method}" != "pipx" && "${method}" != "link" ]]; then
    log_warn "Unsupported COS_INSTALL_METHOD=${method}. Allowed: pipx, link. Falling back to pipx."
    method="pipx"
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    log_warn "python3 is not installed; skipping automatic COS CLI installation."
    log_info "Install Python 3 first, then run: bash ${cos_install_script} --user --method ${method}"
    return 0
  fi

  if [[ "${method}" == "pipx" ]] && ! command -v pipx >/dev/null 2>&1; then
    log_warn "pipx not found; skipping automatic COS CLI installation."
    log_info "Install manually with: bash ${cos_install_script} --user --method pipx"
    return 0
  fi

  log_info "Installing COS CLI (method=${method})..."
  if bash "${cos_install_script}" --user --method "${method}"; then
    log_info "COS CLI installation completed."
    return 0
  fi

  log_warn "COS CLI installation failed; continuing without blocking core deployment."
  return 0
}

explain_ollama_usage() {
  local host_os="$1"
  echo "Ollama powers local embeddings and AI retrieval/context features in Constructos."
  case "$host_os" in
    linux)
      echo "On Linux, you can use Docker Ollama (with GPU when available) or host Ollama."
      ;;
    macos | windows)
      echo "On ${host_os}, you can use host Ollama, and deploy can also try Docker Ollama on supported setups."
      ;;
    *)
      echo "If Ollama is unavailable, AI embedding features will be limited."
      ;;
  esac
}

detect_prompt_device() {
  if [[ -t 0 ]]; then
    echo "stdin"
    return 0
  fi

  if [[ -r /dev/tty && -w /dev/tty ]]; then
    echo "/dev/tty"
    return 0
  fi

  return 1
}

prompt_for_ollama_preference() {
  local host_os="$1"
  local normalized_install_ollama
  local prompt_device=""
  local ollama_choice=""

  if [[ "$DEPLOY_OLLAMA_MODE" != "auto" ]]; then
    return 0
  fi

  if command -v ollama >/dev/null 2>&1; then
    return 0
  fi

  normalized_install_ollama="$(normalize_truthy "${INSTALL_OLLAMA:-auto}")"
  if [[ "$normalized_install_ollama" == "invalid" ]]; then
    log_warn "Unsupported INSTALL_OLLAMA=${INSTALL_OLLAMA}. Allowed: auto, true, false. Falling back to auto."
    INSTALL_OLLAMA="auto"
    normalized_install_ollama="auto"
  fi

  if [[ "$normalized_install_ollama" != "auto" ]]; then
    return 0
  fi

  log_warn "Ollama is not currently installed on this host."
  explain_ollama_usage "$host_os"

  if ! prompt_device="$(detect_prompt_device)"; then
    log_warn "Non-interactive shell detected; cannot prompt for Ollama preference."
    log_warn "Keeping DEPLOY_OLLAMA_MODE=auto."
    return 0
  fi

  while true; do
    if [[ "$host_os" == "macos" ]]; then
      echo "Choose how to continue:"
      echo "1) Continue with Ollama support (host Ollama, recommended)"
      echo "2) Continue without Ollama (AI embedding features will be limited)"
      if [[ "$prompt_device" == "/dev/tty" ]]; then
        printf "Select [1/2]: " >/dev/tty
        read -r ollama_choice </dev/tty
      else
        read -r -p "Select [1/2]: " ollama_choice
      fi
      case "$ollama_choice" in
        1 | "")
          DEPLOY_OLLAMA_MODE="host"
          INSTALL_OLLAMA="true"
          return 0
          ;;
        2)
          DEPLOY_OLLAMA_MODE="none"
          INSTALL_OLLAMA="false"
          log_warn "Continuing without Ollama support."
          return 0
          ;;
        *)
          echo "Please enter 1 or 2."
          ;;
      esac
      continue
    fi

    echo "Choose Ollama runtime:"
    echo "1) Auto (recommended) - try Docker GPU, then host Ollama, then Docker CPU"
    echo "2) Host Ollama only"
    echo "3) Continue without Ollama"
    if [[ "$prompt_device" == "/dev/tty" ]]; then
      printf "Select [1/2/3]: " >/dev/tty
      read -r ollama_choice </dev/tty
    else
      read -r -p "Select [1/2/3]: " ollama_choice
    fi
    case "$ollama_choice" in
      1 | "")
        DEPLOY_OLLAMA_MODE="auto"
        return 0
        ;;
      2)
        DEPLOY_OLLAMA_MODE="host"
        if [[ "$host_os" == "macos" || "$host_os" == "windows" ]]; then
          INSTALL_OLLAMA="true"
        fi
        return 0
        ;;
      3)
        DEPLOY_OLLAMA_MODE="none"
        INSTALL_OLLAMA="false"
        log_warn "Continuing without Ollama support."
        return 0
        ;;
      *)
        echo "Please enter 1, 2, or 3."
        ;;
    esac
  done
}

should_install_ollama() {
  local host_os
  host_os="$(resolve_host_os)"

  if [[ "$DEPLOY_OLLAMA_MODE" == "none" || "$DEPLOY_OLLAMA_MODE" == "docker" || "$DEPLOY_OLLAMA_MODE" == "docker-gpu" ]]; then
    return 1
  fi

  if [[ "$DEPLOY_OLLAMA_MODE" == "host" ]]; then
    if [[ "${INSTALL_OLLAMA:-auto}" == "auto" && ( "$host_os" == "macos" || "$host_os" == "windows" ) ]]; then
      return 0
    fi
  fi

  local normalized_value
  normalized_value="$(normalize_truthy "${INSTALL_OLLAMA:-auto}")"
  case "$normalized_value" in
    true)
      return 0
      ;;
    false)
      return 1
      ;;
    auto)
      if [[ "$host_os" == "macos" ]]; then
        return 0
      fi
      return 1
      ;;
    invalid)
      log_warn "Unsupported INSTALL_OLLAMA=${INSTALL_OLLAMA}. Allowed: auto, true, false. Falling back to auto."
      if [[ "$host_os" == "macos" ]]; then
        return 0
      fi
      return 1
      ;;
  esac
}

resolve_winget_command() {
  if command -v winget >/dev/null 2>&1; then
    printf '%s' "winget"
    return 0
  fi
  if command -v winget.exe >/dev/null 2>&1; then
    printf '%s' "winget.exe"
    return 0
  fi
  return 1
}

install_ollama() {
  local host_os
  host_os="$(resolve_host_os)"

  if ! should_install_ollama; then
    log_info "Skipping Ollama installation (INSTALL_OLLAMA=${INSTALL_OLLAMA})."
    return 0
  fi

  if command -v ollama >/dev/null 2>&1; then
    log_info "Ollama is already installed."
    return 0
  fi

  case "$host_os" in
    macos)
      if ! command -v brew >/dev/null 2>&1; then
        log_warn "Homebrew not found; cannot auto-install Ollama on macOS."
        log_info "Install manually from https://ollama.com/download"
        return 0
      fi

      log_info "Installing Ollama on macOS via Homebrew cask..."
      if ! brew install --cask ollama; then
        log_warn "Ollama installation failed; continuing without blocking core deployment."
        log_info "Install manually from https://ollama.com/download"
        return 0
      fi

      if command -v open >/dev/null 2>&1; then
        open -ga Ollama >/dev/null 2>&1 || true
      fi

      log_info "Ollama installation completed."
      ;;
    windows)
      local winget_cmd
      winget_cmd="$(resolve_winget_command || true)"
      if [[ -z "$winget_cmd" ]]; then
        log_warn "winget was not found; cannot auto-install Ollama on Windows."
        log_info "Install manually from https://ollama.com/download"
        return 0
      fi

      log_info "Installing Ollama on Windows via winget..."
      if ! "$winget_cmd" install --id Ollama.Ollama -e --accept-package-agreements --accept-source-agreements; then
        log_warn "Ollama installation failed; continuing without blocking core deployment."
        log_info "Install manually from https://ollama.com/download"
        return 0
      fi

      log_info "Ollama installation completed."
      ;;
    *)
      log_warn "Automatic Ollama installation is currently supported on macOS and Windows only."
      log_info "Install manually from https://ollama.com/download"
      ;;
  esac

  return 0
}

json_extract_field() {
  local field_name="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json
import sys

field_name = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)

value = payload.get(field_name, "")
if value is None or isinstance(value, (dict, list)):
    sys.exit(0)

print(str(value))
' "$field_name"
    return 0
  fi
  sed -n "s/.*\"${field_name}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n 1
}

exchange_license_token() {
  local activation_code="$1"
  local base_url="${LICENSE_SERVER_URL%/}"
  local endpoint="${base_url}/v1/install/exchange"
  local request_payload
  local response
  local status
  local body
  local exchanged_token
  local detail

  request_payload="$(printf '{"activation_code":"%s"}' "$(printf '%s' "$activation_code" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')")"

  if ! response="$(curl -sS -X POST "$endpoint" -H "Content-Type: application/json" --data "$request_payload" -w $'\n%{http_code}')"; then
    log_error "Failed to reach license server endpoint: ${endpoint}"
    return 1
  fi

  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$status" == "$response" ]]; then
    status=""
    body="$response"
  fi
  if [[ "$status" != "200" ]]; then
    detail="$(printf '%s' "$body" | json_extract_field "detail")"
    if [[ -z "$detail" ]]; then
      detail="$(printf '%s' "$body" | json_extract_field "message")"
    fi
    log_error "Activation code exchange failed (${status:-unknown HTTP status})."
    if [[ -n "$detail" ]]; then
      log_error "Server detail: ${detail}"
    fi
    return 1
  fi

  exchanged_token="$(printf '%s' "$body" | json_extract_field "license_server_token")"
  if [[ -z "$exchanged_token" ]]; then
    log_error "Activation code exchange response did not include license_server_token."
    return 1
  fi

  EXCHANGED_IMAGE_TAG="$(printf '%s' "$body" | json_extract_field "image_tag")"
  LICENSE_SERVER_TOKEN="$exchanged_token"
}

HOST_OS="$(resolve_host_os)"
ensure_docker_available "$HOST_OS" "false" || true
resolve_requested_ollama_mode
prompt_for_ollama_preference "$HOST_OS"

ARCHIVE_URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/${REPO_REF}"
TMP_ARCHIVE="$(mktemp -t constructos-client.XXXXXX.tar.gz)"
trap 'rm -f "$TMP_ARCHIVE"' EXIT

log_info "Downloading ${REPO_OWNER}/${REPO_NAME}@${REPO_REF}..."
curl -fsSL --retry 3 "$ARCHIVE_URL" -o "$TMP_ARCHIVE"
mkdir -p "$INSTALL_DIR"
# GitHub source archives are rooted at <repo>-<ref>/
tar -xzf "$TMP_ARCHIVE" -C "$INSTALL_DIR" --strip-components=1

if [[ -z "$LICENSE_SERVER_TOKEN" && -n "$ACTIVATION_CODE" ]]; then
  exchange_license_token "$ACTIVATION_CODE"
  log_info "Exchanged activation code for LICENSE_SERVER_TOKEN via ${LICENSE_SERVER_URL%/}/v1/install/exchange."
fi

if [[ -z "$IMAGE_TAG" ]]; then
  IMAGE_TAG="${EXCHANGED_IMAGE_TAG:-main}"
fi

if [[ -n "$LICENSE_SERVER_TOKEN" ]]; then
  if [[ -z "$CODEX_CONFIG_FILE" ]]; then
    CODEX_CONFIG_FILE="./codex.config.toml"
  fi
  if [[ -z "$CODEX_AUTH_FILE" ]]; then
    CODEX_AUTH_FILE="${HOME}/.codex/auth.json"
  fi
  ENV_FILE_PATH="$(prepare_env_file "$INSTALL_DIR")"
  upsert_env_value "$ENV_FILE_PATH" "IMAGE_TAG" "$IMAGE_TAG"
  upsert_env_value "$ENV_FILE_PATH" "LICENSE_SERVER_TOKEN" "$LICENSE_SERVER_TOKEN"
  upsert_env_value "$ENV_FILE_PATH" "CODEX_CONFIG_FILE" "$CODEX_CONFIG_FILE"
  upsert_env_value "$ENV_FILE_PATH" "CODEX_AUTH_FILE" "$CODEX_AUTH_FILE"
  upsert_env_value "$ENV_FILE_PATH" "DEPLOY_OLLAMA_MODE" "$DEPLOY_OLLAMA_MODE"
  if [[ "$HOST_OS" == "windows" ]]; then
    upsert_env_value "$ENV_FILE_PATH" "DEPLOY_TARGET" "windows-desktop"
  fi
  log_info "Prepared ${ENV_FILE_PATH} with deploy settings."
fi

install_ollama
install_cos_cli "$INSTALL_DIR"
log_info "Selected Ollama deploy mode: ${DEPLOY_OLLAMA_MODE}"

if is_truthy "$AUTO_DEPLOY"; then
  if [[ -z "$LICENSE_SERVER_TOKEN" ]]; then
    log_error "AUTO_DEPLOY requires LICENSE_SERVER_TOKEN or ACTIVATION_CODE."
    exit 1
  fi
  ensure_docker_available "$HOST_OS" "true"
  log_info "Running deploy in ${INSTALL_DIR}..."
  (
    cd "$INSTALL_DIR"
    IMAGE_TAG="$IMAGE_TAG" \
    LICENSE_SERVER_TOKEN="$LICENSE_SERVER_TOKEN" \
    CODEX_CONFIG_FILE="$CODEX_CONFIG_FILE" \
    CODEX_AUTH_FILE="$CODEX_AUTH_FILE" \
    DEPLOY_OLLAMA_MODE="$DEPLOY_OLLAMA_MODE" \
    bash ./scripts/deploy.sh
  )
  exit 0
fi

echo ""
log_info "Constructos client files installed to: ${INSTALL_DIR}"
log_info "Source: ${ARCHIVE_URL}"
log_info "After deploy, open Constructos at: http://localhost:${APP_PORT:-8080}"
echo ""
echo "Optional integrations:"
echo "- GitHub MCP: set GITHUB_PAT in .env, then set [mcp_servers.github].enabled = true in codex.config.toml and redeploy."
echo "- Jira MCP: cp .env.jira-mcp.example .env.jira-mcp, add credentials, then run:"
echo "  docker compose -p constructos-jira-mcp -f docker-compose.jira-mcp.yml up -d"
echo ""
echo "Next steps:"
echo "1) cd ${INSTALL_DIR}"
if [[ -n "$LICENSE_SERVER_TOKEN" ]]; then
  echo "2) .env is already prepared with IMAGE_TAG and LICENSE_SERVER_TOKEN"
  echo "3) IMAGE_TAG=${IMAGE_TAG} bash ./scripts/deploy.sh"
  echo "4) run 'cos --help' (if COS CLI was installed)"
else
  echo "2) cp .env.example .env (if missing)"
  echo "3) set LICENSE_SERVER_TOKEN in .env"
  echo "4) IMAGE_TAG=${IMAGE_TAG} bash ./scripts/deploy.sh"
  echo "5) run 'cos --help' (if COS CLI was installed)"
fi

echo ""
echo "No-edit install (recommended):"
echo "curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}/install.sh | \\"
echo "  ACTIVATION_CODE='ACT-XXXX-XXXX-XXXX-XXXX-XXXX' IMAGE_TAG=${IMAGE_TAG} INSTALL_COS=true INSTALL_OLLAMA=auto AUTO_DEPLOY=1 bash"
