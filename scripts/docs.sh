#!/bin/bash
# docs.sh — Build and serve the TouchBridge documentation site (Blume).
#
# Usage:
#   bash scripts/docs.sh dev     # dev server with hot reload (http://localhost:4321)
#   bash scripts/docs.sh build   # static build to docs/dist/
#   bash scripts/docs.sh preview # preview the production build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCS_DIR="$PROJECT_DIR/docs"
COMMAND="${1:-dev}"

cd "$DOCS_DIR"

case "$COMMAND" in
  dev)
    echo "Starting Blume dev server at http://localhost:4321…"
    npx blume dev
    ;;
  build)
    echo "Building docs site…"
    npx blume build
    echo "Built to $DOCS_DIR/dist/"
    ;;
  preview)
    echo "Previewing production build…"
    npx blume preview
    ;;
  *)
    echo "Usage: bash scripts/docs.sh [dev|build|preview]"
    exit 1
    ;;
esac
