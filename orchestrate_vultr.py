#!/usr/bin/env python3
"""
Fire-and-forget Vultr benchmark launcher.

Creates instances with a model list encoded in userdata. Each instance reads its
assignment from the Vultr metadata API, runs benchmarks autonomously, and
self-destructs when done. Your laptop can be closed immediately after running this.

The snapshot must have bench-runner.service enabled and /root/run_benchmarks.sh
present. Use setup_snapshot.sh to prepare a snapshot image.

Usage:
  uv run scripts/orchestrate_vultr.py --models anthropic/claude-opus-4.5 --count 1
  uv run scripts/orchestrate_vultr.py --models model1 model2 model3 --count 3

Options:
  --models: Space-separated list of models to benchmark
  --count:  Number of instances to create (default: 1)
            Models are distributed round-robin across instances.
            e.g. 9 models across 3 instances = 3 models per instance.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass

# From previous snapshots 
# bench-runner 2026-03-08 v1
# 38bffed6-4d09-4cf4-840d-0e0180eb0d89
# 
# Full bootstrap
# bench-runner 2026-03-08 v2
# 3924b3f6-d99d-4c6f-8883-43d6d847ff6b

DEFAULT_SNAPSHOT = "38bffed6-4d09-4cf4-840d-0e0180eb0d89"


@dataclass(frozen=True)
class VultrConfig:
    """Configuration for Vultr instance creation."""

    region: str = "atl"
    plan: str = "vc2-1c-2gb"
    snapshot: str = DEFAULT_SNAPSHOT
    ssh_keys: str = "a4b8f6d9-fa2e-48a4-b12d-b6162d065e52"


def create_instance(label: str, models: list[str], config: VultrConfig) -> str:
    """
    Create a Vultr instance with the model list encoded in userdata.

    The instance will read this userdata on boot via the metadata API
    (http://169.254.169.254/v1/user-data) and run benchmarks for all listed models.

    Args:
        label: Label for the instance
        models: List of model IDs this instance should benchmark
        config: Vultr configuration

    Returns:
        Instance ID string

    Raises:
        subprocess.CalledProcessError: If instance creation fails
        json.JSONDecodeError: If response is not valid JSON
    """
    userdata = json.dumps({"models": models})

    print(f"  Creating '{label}' with {len(models)} model(s): {', '.join(models)}")

    result = subprocess.run(
        [
            "vultr",
            "instance",
            "create",
            "--region",
            config.region,
            "--plan",
            config.plan,
            "--snapshot",
            config.snapshot,
            "--ssh-keys",
            config.ssh_keys,
            "--label",
            label,
            "--userdata",
            userdata,
            "--output",
            "json",
        ],
        capture_output=True,
        text=True,
        check=True,
    )

    data = json.loads(result.stdout)
    instance_data = data.get("instance", data)
    instance_id = instance_data["id"]
    print(f"  ✓ {label} created: {instance_id}")
    return instance_id


def distribute_models(models: list[str], count: int) -> list[list[str]]:
    """
    Distribute models across N instances using round-robin assignment.

    Examples:
      9 models, 3 instances → [[m0,m3,m6], [m1,m4,m7], [m2,m5,m8]]
      3 models, 5 instances → [[m0], [m1], [m2], [], []]  (2 instances unused)

    Args:
        models: List of model IDs to distribute
        count: Number of instances

    Returns:
        List of per-instance model lists (some may be empty if count > len(models))
    """
    buckets: list[list[str]] = [[] for _ in range(count)]
    for i, model in enumerate(models):
        buckets[i % count].append(model)
    return buckets


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Launch self-orchestrating Vultr benchmark instances",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Run all models on a single instance
  uv run scripts/orchestrate_vultr.py --models anthropic/claude-opus-4.5 openai/gpt-4o

  # Distribute 30 models across 10 instances (3 models each)
  uv run scripts/orchestrate_vultr.py --count 10 --models model1 model2 ... model30
        """,
    )
    parser.add_argument(
        "--models",
        nargs="+",
        required=True,
        help="Model IDs to benchmark (e.g., anthropic/claude-opus-4.5)",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=1,
        help="Number of instances to create; models distributed round-robin (default: 1)",
    )
    parser.add_argument(
        "--region",
        default="atl",
        help="Vultr region (default: atl)",
    )
    parser.add_argument(
        "--plan",
        default="vc2-1c-2gb",
        help="Vultr plan (default: vc2-1c-2gb)",
    )
    parser.add_argument(
        "--snapshot",
        default=DEFAULT_SNAPSHOT,
        help="Vultr snapshot ID",
    )
    parser.add_argument(
        "--ssh-keys",
        default="a4b8f6d9-fa2e-48a4-b12d-b6162d065e52",
        help="Vultr SSH key ID(s)",
    )

    args = parser.parse_args()

    config = VultrConfig(
        region=args.region,
        plan=args.plan,
        snapshot=args.snapshot,
        ssh_keys=args.ssh_keys,
    )

    buckets = distribute_models(args.models, args.count)
    non_empty = [(i, b) for i, b in enumerate(buckets) if b]

    print(f"\n{'=' * 60}")
    print(f"Vultr Benchmark Launcher")
    print(f"{'=' * 60}")
    print(f"Models:    {len(args.models)}")
    print(f"Instances: {args.count} ({len(non_empty)} with models assigned)")
    print(f"{'=' * 60}\n")

    created: list[tuple[str, str, list[str]]] = []
    failed: list[tuple[str, str]] = []

    for i, model_bucket in non_empty:
        label = f"bench-{i:02d}"
        try:
            instance_id = create_instance(label, model_bucket, config)
            created.append((label, instance_id, model_bucket))
        except subprocess.CalledProcessError as e:
            err = e.stderr.strip() if e.stderr else str(e)
            print(f"  ✗ Failed to create {label}: {err}", file=sys.stderr)
            failed.append((label, err))
        except Exception as e:
            print(f"  ✗ Failed to create {label}: {e}", file=sys.stderr)
            failed.append((label, str(e)))

    print(f"\n{'=' * 60}")
    print(f"Summary")
    print(f"{'=' * 60}")
    print(f"Launched: {len(created)}/{len(non_empty)}")

    for label, iid, models in created:
        print(f"  {label} ({iid})")
        for m in models:
            print(f"    - {m}")

    if failed:
        print(f"\nFailed ({len(failed)}):")
        for label, err in failed:
            print(f"  {label}: {err}")

    print(f"\nInstances will run benchmarks and self-destruct when done.")
    print(f"Monitor: vultr instance list")
    print(f"Logs:    ssh root@<ip> tail -f /var/log/bench-runner.log")
    print(f"{'=' * 60}\n")

    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
