# common-scripts

Small utility scripts I use often.

## Scripts

- `check-docker-desktop.sh`: Quick health check for Docker Desktop integration inside WSL (socket presence, context, and basic `docker info`).
- `cog-serve-http.sh`: Run the Cog HTTP server in the current Cog project (defaults to port 8393). Prints the API base URL and `/docs`.
- `setup-codex-skills-wsl.sh`: Point WSL Codex to the Windows skills directory by setting `CODEX_HOME` in `~/.bashrc`.

## Usage

```bash
./check-docker-desktop.sh
./cog-serve-http.sh
./setup-codex-skills-wsl.sh
```
