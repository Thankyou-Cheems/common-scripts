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
- `scripts/codex/switch-codex-runtime.ps1`: Switch Codex Desktop between Windows App-managed agent and WSL runtime wiring, with network guards for IPv4-only proxy/VPS setups.
- `scripts/codex/repair-codex-history-cwd.ps1`: Normalize Codex transcript and sidebar state `cwd` metadata after moving between WSL `/mnt/<drive>/...` paths and Windows `D:\...` projects.

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

Windows mode uses the Codex Desktop-managed agent from
`%LOCALAPPDATA%\OpenAI\Codex\bin`, not a pnpm/global/standalone Codex CLI shim.

#### Codex History Workspace Repair

When Codex Desktop is moved between WSL and Windows runtime modes, old threads
can remain indexed under `/mnt/d/...`, `C:\mnt\d\...`, or Windows extended paths
such as `\\?\D:\...`. The sidebar may then stop grouping recent threads under
their real Windows projects, or records may briefly appear after restart and
then disappear again after opening a thread.

The repair script fixes both layers:

- transcript source metadata in `~/.codex/sessions/**/*.jsonl`:
  `session_meta`, `turn_context`, `cwd`, `workspace_roots`, and writable roots
- sidebar/state indexes in `state_5.sqlite`, legacy `sqlite/state_5.sqlite`, and
  selected path caches in `.codex-global-state.json`

Preview the current month first:

```powershell
.\scripts\codex\repair-codex-history-cwd.ps1 -WhatIf
```

Repair a specific migration month and restart Codex afterward:

```powershell
.\scripts\codex\repair-codex-history-cwd.ps1 -SessionMonth 2026-06 -RestartApp
```

For a full historical cleanup, use:

```powershell
.\scripts\codex\repair-codex-history-cwd.ps1 -AllSessions -RestartApp
```

The script backs up every changed transcript/state file under
`%USERPROFILE%\.codex\backups\history-cwd-normalize-*`. It only rewrites
structured metadata lines in transcripts; user messages, command output, and
normal conversation content are left untouched.

#### Codex Runtime Network Guard

The runtime switcher is intentionally conservative because this machine can run
behind Clash Verge / Mihomo TUN with a VPS that has IPv4 egress but no IPv6
egress. In that state, Codex Desktop can reconnect repeatedly if Windows or WSL
tries an IPv6 websocket path.

Known-good assumptions:

- The active VPS/proxy egress is IPv4-only unless it has been checked from the
  VPS itself with `curl -6 https://api64.ipify.org`.
- Windows should prefer IPv4-mapped addresses when it still has a native IPv6
  default route.
- WSL should be IPv4-only for Codex unless the active VPS/proxy has proven IPv6
  egress.

Run this once after a fresh machine setup, WSL reset, or network policy reset:

```powershell
.\scripts\codex\switch-codex-runtime.ps1 wsl -ConfigureNetworkGuards
```

`-ConfigureNetworkGuards` does three things:

- sets the Windows IPv6 prefix policy so `::ffff:0:0/96` has higher precedence
  than `::/0`
- writes `%USERPROFILE%\.wslconfig` with `networkingMode=mirrored`,
  `dnsTunneling=true`, `autoProxy=false`, and `ipv6=false`
- writes WSL `/etc/sysctl.d/99-codex-ipv4-only.conf` and `/etc/gai.conf`, then
  runs `wsl --shutdown`

After that, use the normal switch commands:

```powershell
.\scripts\codex\switch-codex-runtime.ps1 windows -RestartApp
.\scripts\codex\switch-codex-runtime.ps1 wsl -RestartApp
```

The script blocks a WSL switch if WSL still has IPv6 enabled or an IPv6 default
route. It also blocks either runtime switch if Windows has an IPv6 default route
but does not prefer IPv4. This is deliberate: blindly switching while the VPS
lacks IPv6 can make Codex Desktop loop through websocket reconnects.

Only bypass the guard when the active proxy/VPS has working IPv6 egress:

```powershell
.\scripts\codex\switch-codex-runtime.ps1 wsl -AllowIpv6
```

Do not treat Clash/Mihomo `ipv6: true` as proof of IPv6 egress. The useful
check is on the VPS:

```bash
curl -6 https://api64.ipify.org
```

If that fails on the VPS, keep Codex on the IPv4-guarded path.

### Cog

```bash
./scripts/cog/cog-serve-http.sh
./scripts/cog/cog-audio-helper.sh /path/to/audio.m4a
```

### Docker

```bash
./scripts/docker/check-docker-desktop.sh
```
