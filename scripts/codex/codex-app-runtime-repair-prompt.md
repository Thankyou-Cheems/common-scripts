# Codex App Runtime Repair Prompt

Use this prompt on another machine when Codex App, IDE integrations, SDKs, or
local helper scripts may depend on a working external `codex` CLI/app-server
runtime.

```text
请排查并修复本机 Codex App/CLI 运行环境。目标不是盲目删除 CLI，而是找出实际入口、保留一个可信的外部 codex CLI，并修复 Desktop App、IDE、SDK、脚本可能依赖的 app-server/runtime 路径。

要求：
1. 先确认操作系统、shell、PATH 顺序和编码；Windows 上优先用 PowerShell 7。不要直接执行 WindowsApps 包内二进制，先用 Get-AppxPackage、Get-Command、where.exe、进程命令行做只读识别。
2. 列出所有 Codex 入口和版本：
   - Get-Command codex -All / where.exe codex
   - standalone install 路径，如 %LOCALAPPDATA%\Programs\OpenAI\Codex\bin\codex.exe
   - npm/pnpm/yarn/bun 全局包和 shim
   - Desktop AppX/应用包内置 resources\codex.exe
   - IDE extension 或 SDK 自带 runtime（如果存在）
3. 区分实际用途：
   - Codex Desktop App 可能使用应用包内置 app-server，不一定依赖外部 CLI。
   - 其他入口可能依赖外部 CLI，例如 `codex app`、`codex app-server`、IDE/SDK/脚本、远程控制或本地自动化。
   - 不要把外部 CLI 升级说成一定会升级 Desktop App 内嵌 app-server。
4. 判断是否有入口冲突：
   - PATH 中是否先命中过旧 pnpm/npm shim。
   - 是否存在多个 `codex` 都能运行但版本不同。
   - 是否存在已卸载包留下的孤儿 shim。
   - 是否有 WindowsApps alias 排在前面或无法直接执行导致 Access denied。
5. 建议的整理策略：
   - 保留官方 standalone CLI 作为外部可信入口，除非机器明确只使用 AppX 且没有任何脚本/IDE/SDK 依赖 `codex`。
   - 保留 Desktop AppX/应用包本体，不把它当作外部 CLI 替代品。
   - 删除或卸载重复的 npm/pnpm 全局 Codex 包；删除卸载后仍污染 PATH 的孤儿 shim，但不要删除 pnpm/npm 本身或其它工具。
   - 如果没有 standalone CLI，而其它工具依赖 `codex`，用官方 install.ps1/install.sh 安装稳定版，不装 alpha，除非用户明确要求。
6. 检查和修复 Codex state/config：
   - 确认 CODEX_HOME、CODEX_SQLITE_HOME、config.toml 的 sqlite_home 是否把状态指到预期位置。
   - 确认 auth/config/skills/plugins/sessions 路径没有被 Windows/WSL 互相误指。
   - 不读出 access token，不输出 auth.json 原文。
7. 验证运行能力：
   - `codex --version` 命中预期 standalone。
   - `codex --help`、`codex app --help`、`codex app-server --help` 成功。
   - 如果需要启动 App，先确认没有现有 Codex 进程冲突，再用 documented/app-supported 方式启动，不强杀用户会话。
   - 如果 IDE/SDK/脚本依赖 CLI，运行一个最小只读 probe，确认它调用的是预期 `codex`。
8. Windows/WSL 特别检查：
   - 分别在 Windows PowerShell 和 WSL shell 中验证 `codex --version`。
   - 如果 WSL 需要调用 Windows Codex，明确处理 PATH/PATHEXT、.exe 调用和 CRLF/quoting；不要让 WSL 误用损坏的 pnpm shim。
   - 如果 Codex Desktop 运行时可切 Windows/WSL runtime，先记录当前 runtime，不擅自切换；切换前检查网络、代理、IPv6/IPv4、wslconfig 和回滚路径。
9. 同步处理已知本地风险：
   - 如果机器存在 logs_*.sqlite feedback log churn 风险，按 Codex SQLite log churn prompt 另行采样和修复，不把日志 guard 和 CLI 入口清理混为同一个结论。
10. 最终报告必须包含：
   - 保留的外部 CLI 路径和版本。
   - Desktop AppX/应用包版本和它是否独立于外部 CLI。
   - 删除了哪些重复包/shim，为什么安全。
   - Windows 与 WSL 两侧 `codex --version` 结果。
   - 仍需用户手动重启的 App/IDE/terminal。
   - 撤销方式或重新安装命令。
```

Core rule: identify the process and command resolution chain first. Keep a
single trusted external CLI if any app, IDE, SDK, or script may call `codex`;
remove stale shims only after proving they are not the active supported entry.
