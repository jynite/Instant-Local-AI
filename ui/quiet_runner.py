#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 saj
# SPDX-License-Identifier: MIT
"""Run a controller command without opening a Windows console window."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def _windows_startup() -> dict[str, object]:
    if os.name != "nt":
        return {}
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = subprocess.SW_HIDE
    return {
        "creationflags": getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000),
        "startupinfo": startup,
    }


def main() -> int:
    command = sys.argv[1:]
    if not command:
        print("quiet_runner.py requires a command", file=sys.stderr)
        return 2
    env = os.environ.copy()
    if len(command) == 1 and Path(command[0]).suffix.lower() == ".bat":
        command = ["cmd.exe", "/d", "/c", command[0]]
        env["JYNERATION_NONINTERACTIVE"] = "1"
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=env,
            **_windows_startup(),
        )
    except OSError as exc:
        print(f"quiet_runner: could not launch command: {exc}", file=sys.stderr)
        return 127
    assert process.stdout is not None
    output = getattr(sys.stdout, "buffer", sys.stdout)
    for line in iter(process.stdout.readline, b""):
        if hasattr(output, "write"):
            output.write(line)
            output.flush()
    return process.wait()


if __name__ == "__main__":
    raise SystemExit(main())
