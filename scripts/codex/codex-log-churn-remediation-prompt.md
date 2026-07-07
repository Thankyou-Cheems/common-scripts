# Codex SQLite Log Churn Remediation Prompt

Use this prompt on another machine to diagnose and stop Codex SQLite feedback
log churn without touching unrelated Codex state.

```text
请检查并修复本机 Codex 是否存在 SQLite feedback log 写放大/写爆 SSD 风险。不要只看文件大小，要做实际采样。

要求：
1. 先确认平台、Codex Desktop App 版本、外部 CLI 版本、实际运行的 app-server 进程命令行。注意 Desktop App 可能使用 AppX/应用包内置的 resources/codex.exe app-server，不等于外部 standalone CLI。
2. 定位 Codex state 目录，默认是 ~/.codex；同时检查 CODEX_HOME、CODEX_SQLITE_HOME、config.toml 里的 sqlite_home。
3. 只读检查所有 logs_*.sqlite 及其 -wal/-shm：文件大小、mtime、logs 表 COUNT(*)、MAX(id)、sqlite_sequence、level/target 聚合。不要输出 feedback_log_body 原文，避免泄露会话内容。
4. 做 60 秒采样：采样前后比较 COUNT(*)、MAX(id)、sqlite_sequence、WAL 文件大小、Codex/app-server 进程 I/O。判断标准：COUNT 基本不变但 MAX(id)/sqlite_sequence 快速增长，说明仍有 insert-and-prune churn。
5. 如果确认 logs 表持续 churn，进行本地可逆止血：对每个有 logs 表的 logs_*.sqlite 执行：
   CREATE TRIGGER IF NOT EXISTS block_log_inserts
   BEFORE INSERT ON logs
   BEGIN
     SELECT RAISE(IGNORE);
   END;
   说明这会关闭本地 persistent feedback log 新增写入，但不应影响会话、配置、登录、代码修改等正常状态库。
6. 修复后再做 60 秒采样，必须证明 COUNT、MAX(id)、sqlite_sequence、logs_*.sqlite-wal 都不再增长。
7. 为防止 Codex 更新后创建新的 logs_N.sqlite，创建一个最小守护脚本，定期扫描 Codex SQLite 目录并补齐 block_log_inserts trigger。优先使用当前用户级自启/计划任务，不要要求管理员权限；脚本只碰 logs_*.sqlite，不读 auth、不输出日志正文、不移动整个 Codex state。
8. 检查外部 CLI 是否冗余或过旧：如果有 standalone、npm/pnpm、AppX 多个入口，保留官方 standalone 和 Desktop 内嵌入口，删除重复的 npm/pnpm 全局 Codex 包或残留 shim。若需要升级外部 CLI，只升稳定版，不用 alpha；同时明确外部 CLI 升级不会升级 Desktop App 内嵌 app-server。
9. 最终报告必须包含：版本、命中的实际入口、修复前后采样数据、已创建的 trigger/watcher 路径、自启项或计划任务状态、可能副作用、撤销命令：
   DROP TRIGGER IF EXISTS block_log_inserts;
```

Core rule: prove write amplification first, block inserts into the `logs`
table, then prove `MAX(id)` has stopped. Do not present external CLI upgrades
as a Desktop App fix.
