#!/usr/bin/env python3
"""
Run scripts/run_parallel_fabric.py sequentially for a list of server JSON files.

Example:
  uv run scripts/run_parallel_batches.py \
    --servers scripts/servers.json scripts/servers2.json scripts/servers3.json

You can pass through any options accepted by run_parallel_fabric.py by placing
them after a "--" separator. For example:
  uv run scripts/run_parallel_batches.py \
    --servers scripts/servers.json scripts/servers2.json -- \
    --user root --workers 8 --remote-dir /root/skill
"""

from __future__ import annotations

import argparse
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Iterable


def parse_args(argv: Iterable[str]) -> tuple[list[Path], list[str]]:
    parser = argparse.ArgumentParser(
        description=(
            "Run scripts/run_parallel_fabric.py sequentially across server JSON files."
        )
    )
    parser.add_argument(
        "--servers",
        nargs="+",
        required=True,
        type=Path,
        help="One or more server JSON files to run in order",
    )
    parser.add_argument(
        "--stop-on-failure",
        action="store_true",
        help="Stop after the first failing batch (non-zero exit code)",
    )
    args, passthrough = parser.parse_known_args(list(argv))

    # Normalize passthrough handling: require "--" to pass args through.
    if passthrough and passthrough[0] == "--":
        passthrough = passthrough[1:]
    elif passthrough:
        parser.error(
            "Unknown arguments. Use '--' to pass options to run_parallel_fabric.py"
        )

    return args.servers, passthrough + (["--stop-on-failure"] if args.stop_on_failure else [])


def build_command(server_path: Path, passthrough: list[str]) -> list[str]:
    return [
        "uv",
        "run",
        "scripts/run_parallel_fabric.py",
        "--servers",
        str(server_path),
        *passthrough,
    ]


def main(argv: Iterable[str]) -> int:
    servers, passthrough = parse_args(argv)
    failures = 0

    for server_path in servers:
        command = build_command(server_path, passthrough)
        print(f"\n=== Running: {shlex.join(command)} ===\n")
        result = subprocess.run(command)
        if result.returncode != 0:
            failures += 1
            if "--stop-on-failure" in passthrough:
                return result.returncode

    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
