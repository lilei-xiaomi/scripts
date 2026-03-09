# Vultr Benchmark Orchestration

## Overview

[`orchestrate_vultr.py`](orchestrate_vultr.py:1) automates the complete end-to-end workflow for running benchmarks on Vultr instances:

1. **Create** Vultr instance via CLI
2. **Wait** for instance to become active and get IP address
3. **Wait** for SSH to be available
4. **Connect** via SSH (auto-accepting host fingerprint)
5. **Register** the instance with `uv run benchmark.py --register`
6. **Run** benchmarks for each specified model
7. **Destroy** the instance
8. **Repeat** for multiple instances (sequential or parallel)

## Prerequisites

1. **Vultr CLI** installed and configured:

   ```bash
   # Install: https://github.com/vultr/vultr-cli
   vultr-cli configure
   ```

2. **SSH key** configured in Vultr and accessible locally

3. **Dependencies** installed:
   ```bash
   uv sync
   ```

## Basic Usage

### Single Instance, Single Model

```bash
uv run scripts/orchestrate_vultr.py --models anthropic/claude-opus-4.5
```

### Multiple Models on One Instance

```bash
uv run scripts/orchestrate_vultr.py \
  --models anthropic/claude-opus-4.5 anthropic/claude-sonnet-4.0 openai/gpt-4
```

### Multiple Instances (Sequential)

```bash
uv run scripts/orchestrate_vultr.py \
  --models anthropic/claude-opus-4.5 \
  --count 3
```

### Multiple Instances (Parallel)

```bash
uv run scripts/orchestrate_vultr.py \
  --models anthropic/claude-opus-4.5 anthropic/claude-sonnet-4.0 \
  --count 5 \
  --parallel \
  --workers 3
```

## Configuration Options

| Option         | Default                                | Description                                            |
| -------------- | -------------------------------------- | ------------------------------------------------------ |
| `--models`     | _required_                             | Model IDs to benchmark (space-separated)               |
| `--count`      | `1`                                    | Number of instances to create and run                  |
| `--parallel`   | `false`                                | Run instances in parallel instead of sequentially      |
| `--workers`    | `4`                                    | Number of parallel workers (when `--parallel` is used) |
| `--key`        | `~/.ssh/id_ed25519`                    | Path to SSH private key                                |
| `--remote-dir` | `/root/skill`                          | Remote directory containing benchmark code             |
| `--region`     | `atl`                                  | Vultr region                                           |
| `--plan`       | `vc2-1c-2gb`                           | Vultr instance plan                                    |
| `--snapshot`   | `9c0c3b2b-2f3e-4ee4-a578-5e5998f23a3a` | Vultr snapshot ID                                      |
| `--ssh-keys`   | `a4b8f6d9-fa2e-48a4-b12d-b6162d065e52` | Vultr SSH key IDs                                      |
| `--userdata`   | `00577bd8-e47f-4e19-a7a9-dd1e54ba0c9c` | Vultr userdata script ID                               |

## Advanced Examples

### Custom SSH Key

```bash
uv run scripts/orchestrate_vultr.py \
  --models anthropic/claude-opus-4.5 \
  --key ~/.ssh/vultr_key
```

### Different Region and Plan

```bash
uv run scripts/orchestrate_vultr.py \
  --models anthropic/claude-opus-4.5 \
  --region ewr \
  --plan vc2-2c-4gb
```

### Large-Scale Parallel Run

```bash
uv run scripts/orchestrate_vultr.py \
  --models model1 model2 model3 model4 model5 \
  --count 10 \
  --parallel \
  --workers 5
```

## How It Works

### 1. Instance Creation

Uses `vultr instance create` with `--output json` to get the instance ID immediately:

```bash
vultr instance create \
  --region atl \
  --plan vc2-1c-2gb \
  --snapshot "..." \
  --label "oc-bench-01" \
  --ssh-keys "..." \
  --userdata "..." \
  --output json
```

### 2. Polling for Ready State

Polls `vultr instance get <id>` until:

- `status == "active"`
- `main_ip != "0.0.0.0"`

### 3. SSH Availability Check

Uses socket connection to probe port 22 until it accepts connections.

### 4. Auto-Accept SSH Fingerprint

Uses Paramiko's `AutoAddPolicy` to automatically accept the host key:

```python
client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
client.connect(ip, username="root", key_filename=key_path)
```

### 5. Remote Command Execution

Runs commands via SSH:

```python
# Registration
client.exec_command("cd /root/skill && uv run benchmark.py --register")

# Benchmarks
client.exec_command(f"cd /root/skill && uv run benchmark.py --model {model}")
```

### 6. Cleanup

Always destroys the instance in a `finally` block to ensure cleanup even on failure:

```bash
vultr instance delete <id> --force
```

## Error Handling

- **Instance creation failures**: Reported immediately, no cleanup needed
- **SSH connection failures**: Instance is destroyed in finally block
- **Benchmark failures**: Logged but don't stop other benchmarks; instance still destroyed
- **Parallel failures**: Each instance is independent; failures don't affect others

## Output

The script provides detailed progress output:

```
============================================================
Vultr Benchmark Orchestration
============================================================
Models: anthropic/claude-opus-4.5, anthropic/claude-sonnet-4.0
Instances: 3
Mode: Parallel
============================================================

Creating instance 'oc-bench-00'...
✓ Instance created: abc123
Waiting for instance abc123 to become active...
✓ Instance active at 1.2.3.4
Waiting for SSH on 1.2.3.4:22...
✓ SSH available on 1.2.3.4
Connecting to 1.2.3.4 via SSH...
✓ Connected to 1.2.3.4
Running registration on 1.2.3.4...
✓ Registration complete on 1.2.3.4
Running benchmark for anthropic/claude-opus-4.5 on 1.2.3.4...
✓ Benchmark complete for anthropic/claude-opus-4.5 on 1.2.3.4
...
Destroying instance abc123...
✓ Instance abc123 destroyed

============================================================
Summary
============================================================
Total: 3
Successful: 3
Failed: 0
============================================================
```

## Troubleshooting

### "vultr: command not found"

Install the Vultr CLI: https://github.com/vultr/vultr-cli

### "paramiko is required"

Install dependencies:

```bash
uv sync
```

### SSH Connection Timeout

- Verify your SSH key is added to Vultr
- Check that the snapshot has SSH properly configured
- Increase timeout with custom `BenchmarkConfig` in the script

### Instance Not Becoming Active

- Check Vultr dashboard for instance status
- Verify snapshot ID is correct
- Try a different region

## Integration with Existing Scripts

This script can be used alongside existing tools:

- **[`run_parallel_fabric.py`](run_parallel_fabric.py:1)**: For running on existing servers
- **[`run_parallel_batches.py`](run_parallel_batches.py:1)**: For batch processing
- **[`create_instance.sh`](create_instance.sh:1)**: Manual instance creation (now automated)

## Cost Considerations

Each instance incurs Vultr charges. The script:

- Destroys instances immediately after benchmarks complete
- Uses `finally` blocks to ensure cleanup even on errors
- Provides summary of all runs for cost tracking

Monitor your Vultr billing dashboard when running large parallel batches.
