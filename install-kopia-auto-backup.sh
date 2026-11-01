#!/usr/bin/env bash
set -Eeuo pipefail

HOME_DIR="${HOME:?HOME non impostata}"
BIN_DIR="$HOME_DIR/.local/bin"
UNIT_DIR="$HOME_DIR/.config/systemd/user"
CONFIG_DIR="$HOME_DIR/.config/kopia-auto-backup"
SCRIPT="$BIN_DIR/kopia-auto-backup.py"
CONFIG_FILE="$CONFIG_DIR/.env"
SOURCE_CONFIG="$(dirname "$(readlink -f "$0")")/.env"

if [[ ! -f "$SOURCE_CONFIG" ]]; then
    echo "File di configurazione non trovato: $SOURCE_CONFIG" >&2
    echo "Crea .env partendo da .env.example e ripeti l'installazione." >&2
    exit 1
fi

CHECK_INTERVAL=""
while IFS='=' read -r key value || [[ -n "${key:-}" ]]; do
    key="${key%%#*}"
    key="${key//[[:space:]]/}"
    [[ "$key" == "CHECK_INTERVAL" ]] && CHECK_INTERVAL="${value%$'\r'}"
done < "$SOURCE_CONFIG"
if [[ ! "$CHECK_INTERVAL" =~ ^[1-9][0-9]*(sec|min|h|d)$ ]]; then
    echo "CHECK_INTERVAL non valido in .env (formato: 15min, 1h, ...)." >&2
    exit 1
fi

mkdir -p "$BIN_DIR" "$UNIT_DIR" "$CONFIG_DIR"
install -m 600 "$SOURCE_CONFIG" "$CONFIG_FILE"

cat > "$SCRIPT" <<'PYTHON'
#!/usr/bin/env python3
"""Avvia gli snapshot Kopia quando il repository è disponibile e ogni sorgente è scaduta."""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

CONFIG_FILE = Path.home() / ".config/kopia-auto-backup/.env"


def load_config() -> dict[str, str]:
    """Legge il semplice formato KEY=value usato dal file .env del progetto."""
    config: dict[str, str] = {}
    try:
        lines = CONFIG_FILE.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise RuntimeError(f"configurazione non leggibile in {CONFIG_FILE}: {exc}") from exc
    for number, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in line:
            raise RuntimeError(f"riga {number} non valida in {CONFIG_FILE}")
        key, value = line.split("=", 1)
        config[key.strip()] = value.strip()
    return config


CONFIG = load_config()
KOPIA = Path(CONFIG["KOPIA_PATH"])
KOPIA_USERNAME = CONFIG["KOPIA_USERNAME"]
KOPIA_HOSTNAME = CONFIG["KOPIA_HOSTNAME"]
MIN_INTERVAL = timedelta(days=int(CONFIG["MIN_INTERVAL_DAYS"]))
REPOSITORY_TIMEOUT_SECONDS = int(CONFIG["REPOSITORY_TIMEOUT_SECONDS"])
LIST_TIMEOUT_SECONDS = int(CONFIG["LIST_TIMEOUT_SECONDS"])
SOURCES = [path for path in CONFIG["SOURCES"].split("|") if path]

STATE_DIR = Path.home() / ".local/state/kopia-auto-backup"
STATE_FILE = STATE_DIR / "state.json"
LOCK_FILE = STATE_DIR / "run.lock"
ENV = os.environ.copy()
ENV["KOPIA_CHECK_FOR_UPDATES"] = "false"


def log(message: str) -> None:
    now = datetime.now().astimezone().isoformat(timespec="seconds")
    print(f"[{now}] {message}", flush=True)


def parse_timestamp(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if result.tzinfo is None:
            result = result.replace(tzinfo=timezone.utc)
        return result.astimezone(timezone.utc)
    except (TypeError, ValueError):
        return None


def load_state() -> dict[str, str]:
    try:
        data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except FileNotFoundError:
        return {}
    except (OSError, json.JSONDecodeError) as exc:
        log(f"ATTENZIONE: stato locale non leggibile ({exc}); uso la cronologia Kopia.")
        return {}


def save_state(state: dict[str, str]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix="state.", dir=STATE_DIR, text=True)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(state, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, STATE_FILE)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def run_capture(args: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(KOPIA), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=ENV,
        timeout=timeout,
        check=False,
    )


def repository_is_available() -> bool:
    try:
        result = run_capture(["repository", "status"], REPOSITORY_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        log("NAS/Kopia non risponde entro il timeout; riprovo al prossimo controllo.")
        return False
    except OSError as exc:
        log(f"Impossibile eseguire Kopia: {exc}")
        return False

    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        if detail:
            log(f"Repository non disponibile: {detail[-1]}")
        else:
            log("Repository non disponibile; riprovo al prossimo controllo.")
        return False

    return True


def read_repository_snapshots() -> dict[str, datetime]:
    result = run_capture(["snapshot", "list", "--json"], LIST_TIMEOUT_SECONDS)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"kopia snapshot list non riuscito: {detail}")

    try:
        snapshots = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"output JSON di Kopia non valido: {exc}") from exc

    if isinstance(snapshots, dict):
        snapshots = snapshots.get("snapshots")
    if not isinstance(snapshots, list):
        raise RuntimeError("formato inatteso restituito da kopia snapshot list --json")

    latest: dict[str, datetime] = {}
    for snapshot in snapshots:
        if not isinstance(snapshot, dict):
            continue
        source = snapshot.get("source") or {}
        if source.get("host") != KOPIA_HOSTNAME or source.get("userName") != KOPIA_USERNAME:
            continue
        if snapshot.get("incomplete"):
            continue

        path = source.get("path")
        timestamp = parse_timestamp(snapshot.get("endTime"))
        if not path or timestamp is None:
            continue
        if path not in latest or timestamp > latest[path]:
            latest[path] = timestamp

    return latest


def snapshot_is_complete(stdout: str) -> bool:
    """Con --json Kopia restituisce il manifest; output vuoto può indicare uno snapshot identico ignorato."""
    if not stdout.strip():
        return True
    try:
        manifest = json.loads(stdout)
    except json.JSONDecodeError:
        return False
    if isinstance(manifest, list):
        return all(not item.get("incomplete") for item in manifest if isinstance(item, dict))
    if isinstance(manifest, dict):
        return not manifest.get("incomplete")
    return False


def main() -> int:
    if not KOPIA.is_file():
        log(f"ERRORE: Kopia CLI non trovato in {KOPIA}.")
        return 1

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with LOCK_FILE.open("w", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("Un controllo/backup è già in esecuzione; esco.")
            return 0

        if not repository_is_available():
            return 0

        try:
            repository_latest = read_repository_snapshots()
        except (RuntimeError, subprocess.TimeoutExpired, OSError) as exc:
            log(f"ERRORE durante la lettura della cronologia Kopia: {exc}")
            return 1

        state = load_state()
        now = datetime.now(timezone.utc)
        due_sources: list[str] = []

        for source in SOURCES:
            source_path = Path(source)
            if not source_path.is_dir():
                log(f"Sorgente assente, salto: {source}")
                continue

            last_repo = repository_latest.get(source)
            last_state = parse_timestamp(state.get(source))
            last_success = max(
                (value for value in (last_repo, last_state) if value is not None),
                default=None,
            )

            if last_success is None:
                log(f"Nessuno snapshot precedente: {source} (da eseguire)")
                due_sources.append(source)
                continue

            age = now - last_success
            if age >= MIN_INTERVAL:
                log(f"Backup scaduto ({age.days} giorni): {source}")
                due_sources.append(source)
            else:
                remaining = MIN_INTERVAL - age
                hours = max(0, int(remaining.total_seconds() // 3600))
                log(f"Ancora {hours} ore prima del prossimo backup: {source}")

        if not due_sources:
            log("Nessuna sorgente da salvare: intervallo minimo di 7 giorni rispettato.")
            return 0

        successes = 0
        failures = 0
        for source in due_sources:
            log(f"Avvio snapshot: {source}")
            try:
                result = subprocess.run(
                    [str(KOPIA), "snapshot", "create", "--json", source],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=None,
                    env=ENV,
                    check=False,
                )
            except OSError as exc:
                log(f"ERRORE eseguendo Kopia per {source}: {exc}")
                failures += 1
                continue

            if result.returncode != 0:
                log(f"BACKUP FALLITO ({result.returncode}): {source}")
                failures += 1
                continue

            if not snapshot_is_complete(result.stdout):
                log(f"Snapshot non completo o output non riconosciuto; non aggiorno la data: {source}")
                failures += 1
                continue

            # Aggiorna lo stato anche se Kopia non salva un nuovo manifest perché i dati sono identici.
            state[source] = datetime.now(timezone.utc).isoformat()
            save_state(state)
            successes += 1
            log(f"Backup completato: {source}")

        log(f"Controllo terminato: {successes} completati, {failures} falliti.")
        return 0 if failures == 0 else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        log("Interrotto dall'utente.")
        raise SystemExit(130)
PYTHON

chmod 700 "$SCRIPT"

cat > "$UNIT_DIR/kopia-auto-backup.service" <<'UNIT'
[Unit]
Description=Kopia automatic backup when NAS is available

[Service]
Type=oneshot
Environment=KOPIA_CHECK_FOR_UPDATES=false
ExecStart=%h/.local/bin/kopia-auto-backup.py
TimeoutStartSec=infinity
UNIT

cat > "$UNIT_DIR/kopia-auto-backup.timer" <<UNIT
[Unit]
Description=Check Kopia backup eligibility every 15 minutes

[Timer]
OnUnitActiveSec=$CHECK_INTERVAL
OnBootSec=2min
Persistent=true
AccuracySec=1min
Unit=kopia-auto-backup.service

[Install]
WantedBy=timers.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now kopia-auto-backup.timer

echo
echo "Installazione completata."
echo "Timer:"
systemctl --user list-timers kopia-auto-backup.timer --no-pager
echo
echo "Per avviare subito un controllo: systemctl --user start kopia-auto-backup.service"
echo "Per vedere i log: journalctl --user -u kopia-auto-backup.service -f"
