#!/usr/bin/env bash
set -euo pipefail

# Find a Windows Codex home that contains skills
win_codex_home=""
for d in /mnt/c/Users/*/.codex; do
  if [ -d "$d/skills" ]; then
    win_codex_home="$d"
    break
  fi
done

if [ -z "$win_codex_home" ]; then
  echo "ERROR: No Windows .codex/skills found under /mnt/c/Users"
  exit 1
fi

bashrc="$HOME/.bashrc"
line="export CODEX_HOME=\"$win_codex_home\""

if rg -q "^export CODEX_HOME=" "$bashrc"; then
  # Replace existing line
  tmp="${bashrc}.tmp"
  awk -v newline="$line" 'BEGIN{replaced=0} /^export CODEX_HOME=/{print newline; replaced=1; next} {print} END{if(!replaced) print newline}' "$bashrc" > "$tmp"
  mv "$tmp" "$bashrc"
else
  printf "\n%s\n" "$line" >> "$bashrc"
fi

echo "CODEX_HOME set to: $win_codex_home"
echo "Open a new shell or run: source ~/.bashrc"
