#!/usr/bin/env bash
# tests/run-suite.sh — run unit + E2E tests
set -euo pipefail
cd "$(dirname "$0")"

echo "╔══════════════════════╗"
echo "║    Unit Tests        ║"
echo "╚══════════════════════╝"
bash run-all.sh

echo ""
echo "╔══════════════════════╗"
echo "║    E2E Tests         ║"
echo "╚══════════════════════╝"
bash e2e/run-e2e.sh

echo ""
echo "════════════════════════"
echo "All suites passed."
