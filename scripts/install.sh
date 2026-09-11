#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build.sh
/usr/bin/python3 - "$PWD/dist/AmzSigning.app" <<'PY'
from pathlib import Path
import fcntl
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

source = Path(sys.argv[1])
root = source.parent.parent
destination = root / "AmzSigning.app"
support = root / "Data"
destination.parent.mkdir(parents=True, exist_ok=True)
support.mkdir(mode=0o700, parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix=".AmzSigning-install-", dir=root / ".build") as temporary:
    staged = Path(temporary) / "AmzSigning.app"
    previous = Path(temporary) / "previous.app"
    shutil.copytree(source, staged, symlinks=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(staged)], check=True)
    descriptor = os.open(support / "worker.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        result = subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", "AmzSigning"], capture_output=True, text=True)
        if result.returncode not in (0, 1):
            raise RuntimeError("无法检查设置应用进程")
        processes = []
        for value in result.stdout.split():
            pid = int(value)
            executable = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True, check=True).stdout.strip()
            if executable == str(destination / "Contents/MacOS/AmzSigning"):
                processes.append(pid)
        for pid in processes:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 5
        while processes:
            remaining = []
            for pid in processes:
                try:
                    os.kill(pid, 0)
                    remaining.append(pid)
                except ProcessLookupError:
                    pass
            if not remaining:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("设置应用尚未退出，安装未替换现有版本")
            processes = remaining
            time.sleep(0.1)
        if destination.exists():
            destination.rename(previous)
        try:
            staged.rename(destination)
        except BaseException:
            if previous.exists():
                previous.rename(destination)
            raise
print(destination)
PY
rm -rf -- "$PWD/.build" "$PWD/.swiftpm" "$PWD/dist"
open "$PWD/AmzSigning.app"
