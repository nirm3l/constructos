# Constructos Client Deployment

This repository contains the client-facing deployment package only.

## One-liner install
```bash
curl -fsSL https://raw.githubusercontent.com/nirm3l/constructos/main/install.sh | IMAGE_TAG=v0.1.230 bash
```

## Manual install
```bash
git clone https://github.com/nirm3l/constructos.git
cd constructos
cp .env.example .env
# edit .env
DEPLOY_SOURCE=ghcr IMAGE_TAG=v0.1.230 bash ./scripts/deploy.sh
```

## Runtime profiles
- `DEPLOY_TARGET=auto|base|ubuntu-gpu|macos-m4` (default: `auto`)
- `DEPLOY_SOURCE=local|ghcr` (default: `local`)
- `GHCR_OWNER` (default: `nirm3l`)
- `GHCR_IMAGE_PREFIX` (default: `constructos`)

## Default GHCR images
- `ghcr.io/nirm3l/constructos-task-app:<tag>`
- `ghcr.io/nirm3l/constructos-mcp-tools:<tag>`

No control-plane or marketing-site services are included in this repository.
