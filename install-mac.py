#!/usr/bin/env python3
"""Install the Mac menu-bar app, preserving the target Mac's input map and rollback copy."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "release" / "显示器切换.app"
DESTINATION = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/Applications/MonitorSwitch.app")
BACKUPS = ROOT / "backups"


def run(*args: str) -> None:
    subprocess.run(args, check=True, capture_output=True, text=True)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def running_pids(bundle: Path) -> list[int]:
    exe = str(bundle / "Contents" / "MacOS" / "MonitorSwitch")
    result = subprocess.run(["/bin/ps", "-axo", "pid=,command="],
                            check=True, capture_output=True, text=True)
    out: list[int] = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].split(" --", 1)[0] == exe:
            out.append(int(parts[0]))
    return out


def main() -> None:
    if not SOURCE.is_dir() or not DESTINATION.is_dir():
        raise SystemExit("Source build or existing target app is missing; no changes made")
    if DESTINATION.is_symlink() or SOURCE.is_symlink():
        raise SystemExit("App path is a symbolic link; no changes made")

    old_config = DESTINATION / "Contents/Resources/config.txt"
    if not old_config.is_file():
        raise SystemExit("Existing input map is missing; no changes made")
    timestamp = dt.datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
    backup = BACKUPS / f"{DESTINATION.stem}-{timestamp}.app"
    BACKUPS.mkdir(exist_ok=True)
    run("/usr/bin/ditto", str(DESTINATION), str(backup))
    if sha256(old_config) != sha256(backup / "Contents/Resources/config.txt"):
        raise SystemExit("Backup verification failed; no changes made")

    staging = DESTINATION.parent / f".{DESTINATION.stem}-staging-{os.getpid()}.app"
    displaced = DESTINATION.parent / f".{DESTINATION.stem}-rollback-{os.getpid()}.app"
    if staging.exists() or displaced.exists():
        raise SystemExit("A staging or rollback path already exists; no changes made")
    try:
        run("/usr/bin/ditto", str(SOURCE), str(staging))
        shutil.copy2(old_config, staging / "Contents/Resources/config.txt")
        run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(staging))
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(staging))
        if sha256(old_config) != sha256(staging / "Contents/Resources/config.txt"):
            raise RuntimeError("Input map differs from the original")

        for pid in running_pids(DESTINATION):
            os.kill(pid, signal.SIGTERM)
        for _ in range(50):
            if not running_pids(DESTINATION):
                break
            time.sleep(0.1)
        if running_pids(DESTINATION):
            raise RuntimeError("Existing app did not exit; original kept")

        os.replace(DESTINATION, displaced)
        try:
            os.replace(staging, DESTINATION)
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(DESTINATION))
            run("/usr/bin/open", str(DESTINATION))
            for _ in range(60):
                if running_pids(DESTINATION):
                    break
                time.sleep(0.1)
            if not running_pids(DESTINATION):
                raise RuntimeError("New app did not start")
        except Exception:
            if DESTINATION.exists():
                shutil.rmtree(DESTINATION)
            os.replace(displaced, DESTINATION)
            run("/usr/bin/open", str(DESTINATION))
            raise
        shutil.rmtree(displaced)
        registry = ("/System/Library/Frameworks/CoreServices.framework/Versions/A/"
                    "Frameworks/LaunchServices.framework/Versions/A/Support/lsregister")
        run(registry, "-f", str(DESTINATION))

        receipt = {
            "installed_at": dt.datetime.now().astimezone().isoformat(),
            "destination": str(DESTINATION),
            "backup": str(backup),
            "config_sha256": sha256(DESTINATION / "Contents/Resources/config.txt"),
            "binary_sha256": sha256(DESTINATION / "Contents/MacOS/MonitorSwitch"),
            "running_pids": running_pids(DESTINATION),
            "display_switch_commands_sent": 0,
        }
        (ROOT / "release/install-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(json.dumps(receipt, ensure_ascii=False))
    finally:
        if staging.exists():
            shutil.rmtree(staging)


if __name__ == "__main__":
    main()
