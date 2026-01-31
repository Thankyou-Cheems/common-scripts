# common-scripts

Small utility scripts I use often.

## Scripts

- `check-docker-desktop.sh`: Quick health check for Docker Desktop integration inside WSL (socket presence, context, and basic `docker info`).
- `cog-serve-http.sh`: Run the Cog HTTP server in the current Cog project (defaults to port 8393). Prints the API base URL and `/docs`.
- `cog-audio-helper.sh`: Convert audio to 16kHz mono WAV, serve it via `host.docker.internal`, and print a ready-to-paste Swagger request body.
- `setup-codex-skills-wsl.sh`: Point WSL Codex to the Windows skills directory by setting `CODEX_HOME` in `~/.bashrc`.
- `easytier-test/`: A collection of PowerShell scripts for testing EasyTier file transfer features (P2P, Relay, Resumability, and Security Gates).

## Usage

### General Scripts
```bash
./check-docker-desktop.sh
./cog-serve-http.sh
./cog-audio-helper.sh /path/to/audio.m4a
./setup-codex-skills-wsl.sh
```

### EasyTier Test Suite
1.  **Configure**: Edit `easytier-test/_common.ps1` and set `$DEFAULT_RELAY_HOST` to your relay server's public IP.
2.  **Run All Tests**:
    ```powershell
    pwsh -File easytier-test/run_suite_transfer.ps1
    ```
3.  **Run Individual Tests**:
    ```powershell
    pwsh -File easytier-test/test_transfer_p2p_basic.ps1
    ```
