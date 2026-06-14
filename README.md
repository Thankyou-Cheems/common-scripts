# common-scripts

Small utility scripts I use often.

## Layout

```text
scripts/
  codex/       Codex desktop/CLI helpers
  cog/         Cog model serving helpers
  docker/      Docker Desktop and WSL checks
obs-studio/
  profiles/    OBS Studio profile presets
```

## Scripts

### Codex

- `scripts/codex/setup-codex-skills-wsl.sh`: Point WSL Codex to the Windows skills directory by setting `CODEX_HOME` in `~/.bashrc`.
- `scripts/codex/switch-codex-runtime.ps1`: Switch Codex Desktop between Windows and WSL runtime wiring.

### Cog

- `scripts/cog/cog-serve-http.sh`: Run the Cog HTTP server in the current Cog project (defaults to port 8393). Prints the API base URL and `/docs`.
- `scripts/cog/cog-audio-helper.sh`: Convert audio to 16kHz mono WAV, serve it via `host.docker.internal`, and print a ready-to-paste Swagger request body.

### Docker

- `scripts/docker/check-docker-desktop.sh`: Quick health check for Docker Desktop integration inside WSL (socket presence, context, and basic `docker info`).

## Configs

- `obs-studio/profiles/`: OBS Studio 4K AV1 output profile presets.

## Usage

### Codex

```bash
./scripts/codex/setup-codex-skills-wsl.sh
```

```powershell
.\scripts\codex\switch-codex-runtime.ps1 windows
.\scripts\codex\switch-codex-runtime.ps1 wsl -RestartApp
```

### Cog

```bash
./scripts/cog/cog-serve-http.sh
./scripts/cog/cog-audio-helper.sh /path/to/audio.m4a
```

### Docker

```bash
./scripts/docker/check-docker-desktop.sh
```
