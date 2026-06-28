#!/usr/bin/env bash
set -euo pipefail

# Build AFFiNE Docker image from a fork with Qwen AI support.
# Prerequisites: Rust toolchain, Node.js >=22.12, yarn, Docker Buildx.
#
# Usage:
#   IMAGE_TAG=vixwillems/affine:canary ./build-fork.sh
#
# Or from repo root:
#   bash .docker/selfhost/build-fork.sh

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || realpath "$(dirname "$0")/../..")"
IMAGE_TAG="${IMAGE_TAG:-vixwillems/affine:canary}"
PLATFORMS="${PLATFORMS:-linux/amd64}"

cd "$REPO_ROOT"

echo "=== Building @affine/server-native (Rust) ==="
yarn affine @affine/server-native build

echo "=== Building @affine/web ==="
yarn affine @affine/web build

echo "=== Building @affine/admin ==="
yarn affine @affine/admin build

echo "=== Building @affine/mobile ==="
yarn affine @affine/mobile build

echo "=== Building @affine/server ==="
yarn affine @affine/server build

echo "=== Preparing node_modules for production ==="
yarn config set --json supportedArchitectures.cpu '["x64", "arm64", "arm"]'
yarn config set --json supportedArchitectures.libc '["glibc"]'
yarn workspaces focus @affine/server --production
yarn workspace @affine/server prisma generate
cp -r ./node_modules ./packages/backend/server/node_modules

echo "=== Building Docker image: $IMAGE_TAG ==="
docker buildx build \
  --platform "$PLATFORMS" \
  --tag "$IMAGE_TAG" \
  --file .github/deployment/node/Dockerfile \
  --load \
  .

echo "=== Done: $IMAGE_TAG ==="
