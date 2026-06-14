#!/usr/bin/env bash
set -euo pipefail

sock="/var/run/docker.sock"

echo "== Docker Desktop WSL check =="

if [ -S "$sock" ]; then
  ls -l "$sock"
else
  echo "ERROR: $sock not found"
  exit 1
fi

echo
echo "Docker context:"
docker context show || true

echo
echo "Docker info (short):"
docker info --format 'Server: {{.ServerVersion}} | OS: {{.OperatingSystem}} | Name: {{.Name}}' || {
  echo "ERROR: cannot connect to docker"
  exit 2
}

echo
echo "OK"
