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
EXCHANGED_IMAGE_TAG=""

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
    echo "Skipping COS CLI installation (INSTALL_COS=${INSTALL_COS})."
    return 0
  fi

  if [[ ! -f "${cos_install_script}" ]]; then
    echo "COS CLI install script not found at ${cos_install_script}; skipping."
    return 0
  fi

  if [[ "${method}" != "pipx" && "${method}" != "link" ]]; then
    echo "Unsupported COS_INSTALL_METHOD=${method}. Allowed: pipx, link. Falling back to pipx."
    method="pipx"
  fi

  if [[ "${method}" == "pipx" ]] && ! command -v pipx >/dev/null 2>&1; then
    echo "pipx not found; skipping automatic COS CLI installation."
    echo "Install manually with: bash ${cos_install_script} --user --method pipx"
    return 0
  fi

  echo "Installing COS CLI (method=${method})..."
  if bash "${cos_install_script}" --user --method "${method}"; then
    echo "COS CLI installation completed."
    return 0
  fi

  echo "COS CLI installation failed; continuing without blocking core deployment."
  return 0
}

json_extract_field() {
  local field_name="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$field_name" <<'PY'
import json
import sys

field_name = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)

value = payload.get(field_name, "")
if value is None:
    sys.exit(0)
if isinstance(value, (dict, list)):
    sys.exit(0)
print(str(value))
PY
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
    echo "Failed to reach license server endpoint: ${endpoint}" >&2
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
    echo "Activation code exchange failed (${status:-unknown HTTP status})." >&2
    if [[ -n "$detail" ]]; then
      echo "Server detail: ${detail}" >&2
    fi
    return 1
  fi

  exchanged_token="$(printf '%s' "$body" | json_extract_field "license_server_token")"
  if [[ -z "$exchanged_token" ]]; then
    echo "Activation code exchange response did not include license_server_token." >&2
    return 1
  fi

  EXCHANGED_IMAGE_TAG="$(printf '%s' "$body" | json_extract_field "image_tag")"
  LICENSE_SERVER_TOKEN="$exchanged_token"
}

ARCHIVE_URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/${REPO_REF}"
TMP_ARCHIVE="$(mktemp -t constructos-client.XXXXXX.tar.gz)"
trap 'rm -f "$TMP_ARCHIVE"' EXIT

curl -fsSL --retry 3 "$ARCHIVE_URL" -o "$TMP_ARCHIVE"
mkdir -p "$INSTALL_DIR"
# GitHub source archives are rooted at <repo>-<ref>/
tar -xzf "$TMP_ARCHIVE" -C "$INSTALL_DIR" --strip-components=1

if [[ -z "$LICENSE_SERVER_TOKEN" && -n "$ACTIVATION_CODE" ]]; then
  exchange_license_token "$ACTIVATION_CODE"
  echo "Exchanged activation code for LICENSE_SERVER_TOKEN via ${LICENSE_SERVER_URL%/}/v1/install/exchange."
fi

if [[ -z "$IMAGE_TAG" ]]; then
  IMAGE_TAG="${EXCHANGED_IMAGE_TAG:-main}"
fi

if [[ -n "$LICENSE_SERVER_TOKEN" ]]; then
  ENV_FILE_PATH="$(prepare_env_file "$INSTALL_DIR")"
  upsert_env_value "$ENV_FILE_PATH" "IMAGE_TAG" "$IMAGE_TAG"
  upsert_env_value "$ENV_FILE_PATH" "LICENSE_SERVER_TOKEN" "$LICENSE_SERVER_TOKEN"
  echo "Prepared ${ENV_FILE_PATH} with IMAGE_TAG and LICENSE_SERVER_TOKEN."
fi

install_cos_cli "$INSTALL_DIR"

if is_truthy "$AUTO_DEPLOY"; then
  if [[ -z "$LICENSE_SERVER_TOKEN" ]]; then
    echo "AUTO_DEPLOY requires LICENSE_SERVER_TOKEN or ACTIVATION_CODE."
    exit 1
  fi
  echo "Running deploy in ${INSTALL_DIR}..."
  (
    cd "$INSTALL_DIR"
    IMAGE_TAG="$IMAGE_TAG" LICENSE_SERVER_TOKEN="$LICENSE_SERVER_TOKEN" bash ./scripts/deploy.sh
  )
  exit 0
fi

echo "Constructos client files installed to: ${INSTALL_DIR}"
echo "Source: ${ARCHIVE_URL}"
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
echo "  ACTIVATION_CODE='ACT-XXXX-XXXX-XXXX-XXXX-XXXX' IMAGE_TAG=${IMAGE_TAG} INSTALL_COS=true AUTO_DEPLOY=1 bash"
