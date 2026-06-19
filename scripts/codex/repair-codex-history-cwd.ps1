[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$CodexHome = (Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex"),

    [string[]]$SessionMonth = @((Get-Date -Format "yyyy-MM")),

    [switch]$AllSessions,

    [switch]$SkipTranscripts,

    [switch]$SkipState,

    [switch]$RestartApp
)

$ErrorActionPreference = "Stop"

function Get-PythonCommand {
    $candidates = @(
        @{ Exe = "python"; Args = @() },
        @{ Exe = "python3"; Args = @() },
        @{ Exe = "py"; Args = @("-3") }
    )

    foreach ($candidate in $candidates) {
        $exe = $candidate.Exe
        $prefixArgs = @($candidate.Args)
        try {
            $probeArgs = @($prefixArgs + @("-c", "import json, sqlite3, sys; print(sys.executable)"))
            $output = & $exe @probeArgs 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($output -join ""))) {
                return [pscustomobject]@{
                    Exe  = $exe
                    Args = $prefixArgs
                }
            }
        } catch {
            continue
        }
    }

    throw "Python with sqlite3 is required. Install Python or make python/python3/py available on PATH."
}

function Stop-CodexApp {
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -ieq "Codex" -or $_.ProcessName -ieq "codex"
    } | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-CodexApp {
    Start-Process explorer.exe "shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App"
}

if (-not (Test-Path -LiteralPath $CodexHome -PathType Container)) {
    throw "Codex home does not exist: $CodexHome"
}

$python = Get-PythonCommand
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-history-cwd-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir -WhatIf:$false | Out-Null

try {
    $optionsPath = Join-Path $tempDir "options.json"
    $helperPath = Join-Path $tempDir "repair_cwd.py"

    $options = [ordered]@{
        codex_home      = (Resolve-Path -LiteralPath $CodexHome).Path
        session_months  = @($SessionMonth)
        all_sessions    = [bool]$AllSessions
        skip_transcripts = [bool]$SkipTranscripts
        skip_state      = [bool]$SkipState
        what_if         = [bool]$WhatIfPreference
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText(
        $optionsPath,
        ($options | ConvertTo-Json -Depth 8),
        $utf8NoBom
    )

    $helper = @'
import json
import os
import re
import shutil
import sqlite3
import sys
import time
from datetime import datetime
from pathlib import Path


def normalize_path(value):
    if not isinstance(value, str):
        return value

    path = value
    if path.startswith("\\\\?\\"):
        path = path[4:]

    if len(path) >= 6 and path.startswith("/mnt/") and path[5].isalpha():
        drive = path[5].upper()
        rest = path[7:] if len(path) > 7 else ""
        path = drive + ":\\" + rest.replace("/", "\\")

    if len(path) >= 8 and path[1:7].lower() == ":\\mnt\\" and path[7].isalpha():
        drive = path[7].upper()
        rest = path[9:] if len(path) > 9 else ""
        path = drive + ":\\" + rest

    if len(path) >= 2 and path[1] == ":" and path[0].isalpha():
        path = path[0].upper() + path[1:]

    return path


def needs_normalize(value):
    return isinstance(value, str) and normalize_path(value) != value


def is_bad_path(value):
    return isinstance(value, str) and (
        value.startswith("/mnt/")
        or value.startswith("\\\\?\\")
        or (len(value) >= 8 and value[1:7].lower() == ":\\mnt\\")
    )


def normalize_list(values):
    if not isinstance(values, list):
        return values, 0

    changed = 0
    normalized = []
    for value in values:
        new_value = normalize_path(value)
        if new_value != value:
            changed += 1
        normalized.append(new_value)
    return normalized, changed


def selected_transcript_files(codex_home, months, all_sessions):
    sessions = codex_home / "sessions"
    archived = codex_home / "archived_sessions"
    paths = []

    if all_sessions:
        if sessions.exists():
            paths.extend(sessions.rglob("*.jsonl"))
        if archived.exists():
            paths.extend(archived.rglob("*.jsonl"))
        return sorted(set(paths))

    for month in months:
        if not re.match(r"^\d{4}-\d{2}$", month):
            raise ValueError(f"Invalid SessionMonth value: {month}")
        year, mon = month.split("-")
        month_dir = sessions / year / mon
        if month_dir.exists():
            paths.extend(month_dir.rglob("*.jsonl"))
        if archived.exists():
            paths.extend(archived.glob(f"rollout-{year}-{mon}-*.jsonl"))

    return sorted(set(paths))


def backup_path_for(backup_root, codex_home, path):
    try:
        rel = path.relative_to(codex_home)
    except ValueError:
        rel = Path(path.name)
    return backup_root / rel


def repair_transcripts(codex_home, backup_root, months, all_sessions, what_if):
    files = selected_transcript_files(codex_home, months, all_sessions)
    changed_files = 0
    changed_fields = 0
    parse_errors = []

    for path in files:
        try:
            raw_lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        except Exception as exc:
            parse_errors.append({"path": str(path), "error": f"read: {exc}"})
            continue

        output = []
        file_changed = False
        file_fields = 0

        for raw in raw_lines:
            newline = "\n" if raw.endswith("\n") else ""
            line = raw[:-1] if newline else raw
            if not line.strip():
                output.append(raw)
                continue

            try:
                obj = json.loads(line)
            except Exception:
                output.append(raw)
                continue

            if obj.get("type") in ("session_meta", "turn_context") and isinstance(obj.get("payload"), dict):
                payload = obj["payload"]

                old_cwd = payload.get("cwd")
                new_cwd = normalize_path(old_cwd)
                if new_cwd != old_cwd:
                    payload["cwd"] = new_cwd
                    file_changed = True
                    file_fields += 1

                if "workspace_roots" in payload:
                    new_roots, count = normalize_list(payload.get("workspace_roots"))
                    if count:
                        payload["workspace_roots"] = new_roots
                        file_changed = True
                        file_fields += count

                sandbox = payload.get("sandbox_policy")
                if isinstance(sandbox, dict) and "writable_roots" in sandbox:
                    new_roots, count = normalize_list(sandbox.get("writable_roots"))
                    if count:
                        sandbox["writable_roots"] = new_roots
                        file_changed = True
                        file_fields += count

                output.append(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + newline)
            else:
                output.append(raw)

        if file_changed:
            changed_files += 1
            changed_fields += file_fields
            if not what_if:
                backup = backup_path_for(backup_root, codex_home, path)
                backup.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, backup)
                path.write_text("".join(output), encoding="utf-8", newline="")

    return {
        "scanned_files": len(files),
        "changed_files": changed_files,
        "changed_fields": changed_fields,
        "parse_errors": parse_errors,
    }


def repair_global_state(codex_home, backup_root, what_if):
    path = codex_home / ".codex-global-state.json"
    if not path.exists():
        return {"changed_fields": 0}

    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"error": str(exc), "changed_fields": 0}

    changed = 0
    atom = state.get("electron-persisted-atom-state")
    if isinstance(atom, dict):
        collapsed = atom.get("sidebar-collapsed-groups")
        if isinstance(collapsed, dict):
            new_collapsed = {}
            for key, value in collapsed.items():
                new_key = normalize_path(key)
                if new_key != key:
                    changed += 1
                new_collapsed[new_key] = value
            atom["sidebar-collapsed-groups"] = new_collapsed

        for key in ("thread-workspace-root-hints", "thread-projectless-output-directories"):
            mapping = atom.get(key)
            if isinstance(mapping, dict):
                for item_key, item_value in list(mapping.items()):
                    new_value = normalize_path(item_value)
                    if new_value != item_value:
                        mapping[item_key] = new_value
                        changed += 1

    for key in ("electron-saved-workspace-roots", "active-workspace-roots", "project-order", "pinned-project-ids"):
        values = state.get(key)
        new_values, count = normalize_list(values)
        if count:
            state[key] = new_values
            changed += count

    if changed and not what_if:
        backup = backup_root / ".codex-global-state.json"
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, backup)
        path.write_text(json.dumps(state, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")

    return {"changed_fields": changed}


def repair_sqlite_state(codex_home, backup_root, what_if):
    dbs = [
        ("root", codex_home / "state_5.sqlite"),
        ("legacy-sqlite", codex_home / "sqlite" / "state_5.sqlite"),
    ]
    results = []

    for label, db_path in dbs:
        if not db_path.exists():
            continue

        last_error = None
        for _ in range(5):
            try:
                con = sqlite3.connect(db_path, timeout=15)
                con.execute("pragma busy_timeout=15000")
                columns = [row[1] for row in con.execute("pragma table_info(threads)").fetchall()]
                if "cwd" not in columns:
                    con.close()
                    results.append({"db": str(db_path), "label": label, "updated_rows": 0, "remaining_bad": 0})
                    break

                rows = con.execute("select id, cwd from threads where cwd is not null").fetchall()
                bad_before = sum(1 for _, cwd in rows if is_bad_path(cwd))
                bad_after = sum(1 for _, cwd in rows if is_bad_path(normalize_path(cwd)))
                updates = []
                for thread_id, cwd in rows:
                    new_cwd = normalize_path(cwd)
                    if new_cwd != cwd:
                        updates.append((new_cwd, thread_id))

                if updates and not what_if:
                    backup = backup_root / f"{label}-state_5.sqlite"
                    dst = sqlite3.connect(backup)
                    con.backup(dst)
                    dst.close()
                    with con:
                        con.executemany("update threads set cwd = ? where id = ?", updates)

                remaining_bad = bad_after
                if not what_if:
                    rows_after = con.execute("select cwd from threads where cwd is not null").fetchall()
                    remaining_bad = sum(1 for (cwd,) in rows_after if is_bad_path(cwd))
                con.close()
                results.append({
                    "db": str(db_path),
                    "label": label,
                    "updated_rows": len(updates),
                    "bad_before": bad_before,
                    "remaining_bad": remaining_bad,
                })
                break
            except Exception as exc:
                last_error = exc
                time.sleep(2)
        else:
            results.append({"db": str(db_path), "label": label, "error": str(last_error)})

    return results


def main():
    options = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    codex_home = Path(options["codex_home"])
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_root = codex_home / "backups" / f"history-cwd-normalize-{stamp}"
    if not options["what_if"]:
        backup_root.mkdir(parents=True, exist_ok=True)

    summary = {
        "codex_home": str(codex_home),
        "backup_root": str(backup_root),
        "what_if": options["what_if"],
        "transcripts": None,
        "global_state": None,
        "sqlite_state": None,
    }

    if not options["skip_transcripts"]:
        summary["transcripts"] = repair_transcripts(
            codex_home,
            backup_root,
            options["session_months"],
            options["all_sessions"],
            options["what_if"],
        )

    summary["global_state"] = repair_global_state(codex_home, backup_root, options["what_if"])

    if not options["skip_state"]:
        summary["sqlite_state"] = repair_sqlite_state(codex_home, backup_root, options["what_if"])

    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
'@

    [System.IO.File]::WriteAllText($helperPath, $helper, $utf8NoBom)

    if ($RestartApp -and -not $WhatIfPreference) {
        Write-Host "Stopping Codex before history cwd repair..."
        Stop-CodexApp
        Start-Sleep -Seconds 2
    } elseif ($RestartApp) {
        Write-Host "WhatIf: skipping Codex restart."
    }

    $pythonArgs = @($python.Args + @($helperPath, $optionsPath))
    $json = & $python.Exe @pythonArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Codex history cwd repair failed."
    }
    $jsonText = $json -join "`n"
    Write-Host $jsonText

    if ($RestartApp -and -not $WhatIfPreference) {
        Write-Host "Starting Codex..."
        Start-CodexApp
        Start-Sleep -Seconds 10

        $postOptions = $options.Clone()
        $postOptions.skip_transcripts = $true
        [System.IO.File]::WriteAllText(
            $optionsPath,
            ($postOptions | ConvertTo-Json -Depth 8),
            $utf8NoBom
        )
        $postJson = & $python.Exe @pythonArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Post-restart Codex state cwd repair failed."
        }
        Write-Host ($postJson -join "`n")
    }
} finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
}
