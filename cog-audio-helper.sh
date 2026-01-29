#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  cog-audio-helper.sh <audio_path> [--port 8000] [--no-serve]

Converts audio to 16kHz mono WAV (if needed) and optionally starts a local
HTTP server so Docker can download the file via host.docker.internal.

Examples:
  cog-audio-helper.sh "C:\Users\me\Downloads\audio.m4a"
  cog-audio-helper.sh /home/me/audio.wav --port 8001
  cog-audio-helper.sh /home/me/audio.m4a --no-serve
EOF
}

if [[ "${1-}" == "-h" || "${1-}" == "--help" || "$#" -lt 1 ]]; then
  usage
  exit 0
fi

audio_path="$1"
shift

port=8000
serve=1
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --port)
      port="${2-8000}"
      shift 2
      ;;
    --port=*)
      port="${1#--port=}"
      shift
      ;;
    --no-serve)
      serve=0
      shift
      ;;
    *)
      echo "ERROR: Unknown option: $1"
      exit 1
      ;;
  esac
done

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ERROR: ffmpeg not found in PATH"
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found in PATH"
  exit 1
fi

# Convert Windows path to WSL path if needed
if [[ "$audio_path" =~ ^[A-Za-z]:\\ ]]; then
  drive="$(printf '%s' "$audio_path" | cut -d':' -f1 | tr 'A-Z' 'a-z')"
  rest="${audio_path#?:\\}"
  rest="${rest//\\//}"
  audio_path="/mnt/${drive}/${rest}"
fi

if [[ ! -f "$audio_path" ]]; then
  echo "ERROR: File not found: $audio_path"
  exit 1
fi

ext="${audio_path##*.}"
ext="$(printf '%s' "$ext" | tr 'A-Z' 'a-z')"

out_dir="$(pwd)/_cog_audio"
mkdir -p "$out_dir"
base_name="$(basename "$audio_path")"
stem="${base_name%.*}"
out_file="${out_dir}/${stem}.wav"

if [[ "$ext" != "wav" ]]; then
  echo "Converting to WAV: $out_file"
  ffmpeg -y -i "$audio_path" -ar 16000 -ac 1 "$out_file" >/dev/null 2>&1
else
  out_file="$audio_path"
fi

audio_url="http://host.docker.internal:${port}/$(basename "$out_file")"

echo "Use this in JSON:"
echo "  \"audio\": \"${audio_url}\""
echo
echo "Swagger request body (paste into /predictions):"
cat <<EOF
{
  "input": {
    "audio": "${audio_url}",
    "llm_prompt": null,
    "include_timestamps": true,
    "show_confidence": false
  }
}
EOF

if [[ "$serve" -eq 1 ]]; then
  echo "Serving: $out_file"
  echo "Open docs: http://localhost:8393/docs"
  echo "Starting file server on port ${port} (Ctrl+C to stop)..."
  (cd "$(dirname "$out_file")" && python3 -m http.server "$port")
fi
