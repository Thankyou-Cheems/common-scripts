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

port="${PORT:-}"
args=("$@")

if [ "${#args[@]}" -eq 0 ]; then
  port="${port:-8393}"
  args=(-p "$port")
else
  # Parse -p/--port flags if provided
  for ((i=0; i<${#args[@]}; i++)); do
    case "${args[$i]}" in
      -p|--port)
        if [ $((i+1)) -lt ${#args[@]} ]; then
          port="${args[$((i+1))]}"
        fi
        ;;
      --port=*)
        port="${args[$i]#--port=}"
        ;;
    esac
  done
  port="${port:-8393}"
fi

echo "Open: http://localhost:${port}/"
echo "Docs: http://localhost:${port}/docs"
exec cog serve "${args[@]}"
