# Constructos Client Deployment

This repository contains the client-facing deployment package only.

## One-liner install
```bash
curl -fsSL https://raw.githubusercontent.com/nirm3l/constructos/main/install.sh | ACTIVATION_CODE=ACT-XXXX-XXXX-XXXX-XXXX-XXXX IMAGE_TAG=main AUTO_DEPLOY=1 bash
```

## Manual install
```bash
git clone https://github.com/nirm3l/constructos.git
cd constructos
ACTIVATION_CODE=ACT-XXXX-XXXX-XXXX-XXXX-XXXX IMAGE_TAG=main bash ./install.sh
# or: set LICENSE_SERVER_TOKEN manually in .env, then deploy
IMAGE_TAG=main bash ./scripts/deploy.sh
```

## Runtime profiles
- `DEPLOY_TARGET=auto|base|ubuntu-gpu|macos-m4` (default: `auto`)
- `IMAGE_TAG=<tag>` (default: `main`)
- `ACTIVATION_CODE` (recommended)
- `LICENSE_SERVER_TOKEN` (manual fallback)
- `LICENSE_SERVER_URL` (optional, default: `https://licence.constructos.dev`)

## Default GHCR images
- `ghcr.io/nirm3l/constructos-task-app:<tag>`
- `ghcr.io/nirm3l/constructos-mcp-tools:<tag>`
