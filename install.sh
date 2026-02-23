#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="${REPO_OWNER:-nirm3l}"
REPO_NAME="${REPO_NAME:-constructos}"
REPO_REF="${REPO_REF:-main}"
INSTALL_DIR="${INSTALL_DIR:-./constructos-client}"
IMAGE_TAG="${IMAGE_TAG:-}"

ARCHIVE_URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/${REPO_REF}"
TMP_ARCHIVE="$(mktemp -t constructos-client.XXXXXX.tar.gz)"
trap 'rm -f "$TMP_ARCHIVE"' EXIT

curl -fsSL --retry 3 "$ARCHIVE_URL" -o "$TMP_ARCHIVE"
mkdir -p "$INSTALL_DIR"
# GitHub source archives are rooted at <repo>-<ref>/
tar -xzf "$TMP_ARCHIVE" -C "$INSTALL_DIR" --strip-components=1

if [[ -z "$IMAGE_TAG" ]]; then
  IMAGE_TAG="vX.Y.Z"
fi

echo "Constructos client files installed to: ${INSTALL_DIR}"
echo "Source: ${ARCHIVE_URL}"
echo "Next steps:"
echo "1) cd ${INSTALL_DIR}"
echo "2) cp .env.example .env"
echo "3) edit .env values"
echo "4) DEPLOY_SOURCE=ghcr IMAGE_TAG=${IMAGE_TAG} ./scripts/deploy.sh"
