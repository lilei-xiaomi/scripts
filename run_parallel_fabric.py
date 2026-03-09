#!/usr/bin/env python3
"""
Run benchmark commands in parallel across multiple servers using Fabric.

python scripts/run_parallel_fabric.py --servers servers.json 
The script supports --user, --port, --key, --password, --connect-timeout, 
--remote-dir, --command-template, and --workers.

Input JSON format:
[
  {"host": "1.2.3.4", "model": "anthropic/claude-opus-4.5"},
  {"host": "5.6.7.8", "model": "anthropic/claude-sonnet-4.0"}
]
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

from fabric import Connection
from invoke.exceptions import UnexpectedExit
from concurrent.futures import ThreadPoolExecutor, as_completed


@dataclass(frozen=True)
class ServerEntry:
    host: str
    model: str


def load_servers(path: Path) -> Sequence[ServerEntry]:
    try:
        raw = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise ValueError(f"Invalid JSON in {path}: {exc}") from exc

    if not isinstance(raw, list):
        raise ValueError("Servers JSON must be a list of objects")

    servers: list[ServerEntry] = []
    for idx, entry in enumerate(raw, start=1):
        if not isinstance(entry, dict):
            raise ValueError(f"Entry {idx} must be an object")
        host = entry.get("host")
        model = entry.get("model")
        if not host or not model:
            raise ValueError(f"Entry {idx} requires 'host' and 'model'")
        servers.append(ServerEntry(host=str(host), model=str(model)))
    return servers


def build_command(command_template: str, model: str, remote_dir: str) -> str:
    rendered = command_template.format(model=model)
    base_command = (
        f"cd {remote_dir} && git pull && {rendered}"
    )
    return f"/bin/bash -lc {json.dumps(base_command)}"


def run_on_server(
    server: ServerEntry,
    user: str,
    port: int,
    key_filename: str | None,
    password: str | None,
    connect_timeout: int | None,
    command_template: str,
    remote_dir: str,
) -> tuple[str, bool, str]:
    connect_kwargs = {}
    if key_filename:
        connect_kwargs["key_filename"] = key_filename
    if password:
        connect_kwargs["password"] = password

    command = build_command(command_template, server.model, remote_dir)

    try:
        conn = Connection(
            host=server.host,
            user=user,
            port=port,
            connect_timeout=connect_timeout,
            connect_kwargs=connect_kwargs or None,
        )
        result = conn.run(command, hide=False, warn=True)
        ok = result.ok
        output = result.stdout or ""
        if result.stderr:
            output += f"\nSTDERR:\n{result.stderr}"
        return server.host, ok, output
    except UnexpectedExit as exc:
        return server.host, False, f"Command failed: {exc.result}"
    except Exception as exc:  # pragma: no cover - defensive
        return server.host, False, f"Error: {exc}"


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run benchmark.py on multiple servers in parallel using Fabric."
    )
    parser.add_argument(
        "--servers",
        required=True,
        type=Path,
        help="Path to JSON file with host/model entries",
    )
    parser.add_argument("--user", default="root", help="SSH username")
    parser.add_argument("--port", type=int, default=22, help="SSH port")
    parser.add_argument(
        "--key",
        dest="key_filename",
        default=None,
        help="Path to SSH private key",
    )
    parser.add_argument(
        "--password",
        default=None,
        help="SSH password (not recommended if using keys)",
    )
    parser.add_argument(
        "--connect-timeout",
        type=int,
        default=10,
        help="SSH connect timeout in seconds",
    )
    parser.add_argument(
        "--remote-dir",
        default="/root/skill",
        help="Directory to cd into before running the command",
    )
    parser.add_argument(
        "--command-template",
        default="uv run benchmark.py --model {model}",
        help="Command template; must include {model}",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=8,
        help="Maximum number of concurrent workers",
    )
    return parser.parse_args(list(argv))


def main(argv: Iterable[str]) -> int:
    args = parse_args(argv)
    servers = load_servers(args.servers)

    if "{model}" not in args.command_template:
        raise ValueError("--command-template must include '{model}'")

    failures = 0
    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = [
            executor.submit(
                run_on_server,
                server,
                args.user,
                args.port,
                args.key_filename,
                args.password,
                args.connect_timeout,
                args.command_template,
                args.remote_dir,
            )
            for server in servers
        ]
        for future in as_completed(futures):
            host, ok, output = future.result()
            status = "OK" if ok else "FAILED"
            print(f"[{status}] {host}")
            if output:
                print(output.strip())
            if not ok:
                failures += 1

    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
