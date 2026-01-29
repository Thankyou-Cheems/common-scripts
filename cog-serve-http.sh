#!/usr/bin/env bash
set -euo pipefail

if ! command -v cog >/dev/null 2>&1; then
  echo "ERROR: 'cog' not found in PATH"
  exit 1
fi

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
  cat <<'EOF'
Usage:
  cog-serve-http.sh [cog serve args...]

Examples:
  cog-serve-http.sh                 # defaults to -p 5000
  cog-serve-http.sh -p 5001         # override port
  cog-serve-http.sh --gpus all -p 5000

This runs:
  cog serve [args...]
EOF
  exit 0
fi

if [ "$#" -eq 0 ]; then
  set -- -p "${PORT:-5000}"
fi

exec cog serve "$@"
