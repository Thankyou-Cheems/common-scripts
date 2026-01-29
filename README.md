# common-scripts

Small utility scripts I use often.

## Scripts

- `check-docker-desktop.sh`: Quick health check for Docker Desktop integration inside WSL (socket presence, context, and basic `docker info`).
- `cog-serve-http.sh`: Run the Cog HTTP server in the current Cog project (defaults to port 8393). Prints the API base URL and `/docs`.
- `cog-audio-helper.sh`: Convert audio to 16kHz mono WAV, serve it via `host.docker.internal`, and print a ready-to-paste Swagger request body.
- `setup-codex-skills-wsl.sh`: Point WSL Codex to the Windows skills directory by setting `CODEX_HOME` in `~/.bashrc`.

## Usage

```bash
./check-docker-desktop.sh
./cog-serve-http.sh
./cog-audio-helper.sh /path/to/audio.m4a
./setup-codex-skills-wsl.sh
```
