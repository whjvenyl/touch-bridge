#!/bin/bash
# docs.sh — Build and serve the TouchBridge documentation site (Blume).
#
# Usage:
#   bash scripts/docs.sh dev      # dev server with hot reload (http://localhost:4321)
#   bash scripts/docs.sh build    # static build to docs/dist/
#   bash scripts/docs.sh preview  # preview the production build
#   bash scripts/docs.sh check    # type-check the site
#   bash scripts/docs.sh validate # validate links across content
#   bash scripts/docs.sh audit    # audit built site for SEO and health

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCS_DIR="$PROJECT_DIR/docs"
COMMAND="${1:-dev}"

cd "$DOCS_DIR"

case "$COMMAND" in
  dev)
    echo "Starting Blume dev server at http://localhost:4321…"
    npm run dev
    ;;
  build)
    echo "Building docs site…"
    npm run build
    echo "Built to $DOCS_DIR/dist/"
    ;;
  preview)
    echo "Previewing production build…"
    npm run preview
    ;;
  check)
    echo "Type-checking docs site…"
    npm run check
    ;;
  validate)
    echo "Validating links…"
    npm run validate
    ;;
  audit)
    echo "Auditing built site…"
    npm run audit
    ;;
  *)
    echo "Usage: bash scripts/docs.sh [dev|build|preview|check|validate|audit]"
    exit 1
    ;;
esac
