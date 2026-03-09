#!/bin/bash
# Autonomous benchmark runner — runs on each Vultr instance at boot.
#
# Reads the model list from the Vultr instance metadata API (set as userdata
# by the orchestrator), runs registration and benchmarks for each model,
# then self-destructs the instance.
#
# This script is invoked by bench-runner.service (systemd) on first boot.
# It should be placed at /root/run_benchmarks.sh on the snapshot image.
# Use setup_snapshot.sh to install it.

set -uo pipefail

LOG="/var/log/bench-runner.log"
REMOTE_DIR="/root/skill"
METADATA="http://169.254.169.254"

# Tee all output to log file
exec > >(tee -a "$LOG") 2>&1

echo "=== Benchmark runner started at $(date -u) ==="
echo "Hostname: $(hostname)"

# ── Load environment (API keys, PATH additions for uv, etc.) ──
# shellcheck source=/dev/null
source /root/.profile 2>/dev/null || true
# shellcheck source=/dev/null
source /root/.bashrc 2>/dev/null || true
# Load system-wide env (contains VULTR_API_KEY for self-destruct)
set -o allexport
# shellcheck source=/dev/null
source /etc/environment 2>/dev/null || true
set +o allexport

# ── Verify required tools ──
for tool in curl jq uv vultr; do
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: '$tool' not found in PATH (PATH=$PATH)"
        exit 1
    fi
done

# ── Get instance ID from Vultr metadata ──
echo "Fetching instance metadata..."
INSTANCE_ID=""
for attempt in $(seq 1 12); do
    INSTANCE_ID=$(curl -sf --retry 3 --retry-delay 5 "$METADATA/v1/instance-v2-id" 2>/dev/null || true)
    if [ -n "$INSTANCE_ID" ]; then
        break
    fi
    echo "  Metadata not ready (attempt $attempt/12), retrying in 10s..."
    sleep 10
done

if [ -z "$INSTANCE_ID" ]; then
    echo "ERROR: Could not retrieve instance ID from metadata API after 2 minutes"
    exit 1
fi

echo "Instance ID: $INSTANCE_ID"

# ── Register a safety-net self-destruct in 5 hours ──
# This fires even if the benchmarks hang or the runner crashes after registration.
# Requires 'at' to be available (installed by setup_snapshot.sh).
if command -v at &>/dev/null && [ -n "$INSTANCE_ID" ]; then
    echo "vultr instance delete $INSTANCE_ID --force" | at now + 5 hours 2>/dev/null && \
        echo "Safety-net self-destruct scheduled in 5 hours" || \
        echo "WARNING: Could not schedule safety-net self-destruct (at daemon not running?)"
fi

# ── Read model list from userdata ──
echo "Fetching userdata..."
USERDATA=$(curl -sf --retry 5 --retry-delay 3 "$METADATA/v1/user-data" 2>/dev/null || true)

if [ -z "$USERDATA" ]; then
    echo "ERROR: userdata is empty — was this instance launched by the orchestrator?"
    exit 1
fi

echo "Userdata: $USERDATA"

# Parse models array from JSON: {"models": ["model1", "model2"]}
mapfile -t MODELS < <(echo "$USERDATA" | jq -r '.models[]' 2>/dev/null)

if [ ${#MODELS[@]} -eq 0 ]; then
    echo "ERROR: No models found in userdata JSON (expected {\"models\": [...]})"
    echo "Raw userdata was: $USERDATA"
    exit 1
fi

echo "Models assigned to this instance:"
for m in "${MODELS[@]}"; do
    echo "  - $m"
done

# ── Pull latest benchmark code ──
echo ""
echo "=== Updating benchmark code ==="
cd "$REMOTE_DIR"
git pull || echo "WARNING: git pull failed, continuing with existing code"

# ── Registration ──
echo ""
echo "=== Running registration ==="
if ! uv run benchmark.py --register; then
    echo "ERROR: Registration failed"
    # Self-destruct even on registration failure to avoid orphaned billing
    echo "Self-destructing after registration failure..."
    vultr instance delete "$INSTANCE_ID" --force || true
    exit 1
fi
echo "✓ Registration complete"

# ── Run benchmarks ──
FAILED_MODELS=()

for model in "${MODELS[@]}"; do
    echo ""
    echo "=== Benchmarking: $model ==="
    echo "Started at: $(date -u)"

    if uv run benchmark.py --model "$model"; then
        echo "✓ $model complete at $(date -u)"
    else
        echo "✗ $model failed at $(date -u)"
        FAILED_MODELS+=("$model")
    fi
done

# ── Summary ──
echo ""
echo "=== Run complete at $(date -u) ==="
echo "Total models: ${#MODELS[@]}"
echo "Failed:       ${#FAILED_MODELS[@]}"
if [ ${#FAILED_MODELS[@]} -gt 0 ]; then
    echo "Failed models:"
    for m in "${FAILED_MODELS[@]}"; do
        echo "  - $m"
    done
fi

# ── Self-destruct ──
echo ""
echo "=== Deleting instance $INSTANCE_ID ==="
if vultr instance delete "$INSTANCE_ID" --force; then
    echo "✓ Instance deletion requested"
else
    echo "WARNING: Self-destruct failed — instance $INSTANCE_ID may need manual cleanup"
    echo "Run: vultr instance delete $INSTANCE_ID --force"
fi
