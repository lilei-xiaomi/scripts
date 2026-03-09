#!/bin/bash
# Prepare a Vultr instance to be snapshotted for headless benchmark execution.
#
# Run this script on a fresh Vultr instance (SSH in as root) BEFORE taking a
# snapshot. After running this and taking a snapshot, instances launched from
# that snapshot will run benchmarks autonomously and self-destruct when done.
#
# Usage (from your laptop):
#   scp scripts/bench_runner.sh scripts/bench-runner.service root@<instance-ip>:/tmp/
#   ssh root@<instance-ip> 'bash /tmp/setup_snapshot.sh'
#
# Or from the instance itself if you've cloned the repo there:
#   bash pinchbench/scripts/setup_snapshot.sh
#
# After this script completes:
#   1. Verify the service is enabled: systemctl is-enabled bench-runner
#   2. Confirm /root/run_benchmarks.sh exists and is executable
#   3. Confirm VULTR_API_KEY is set in /etc/environment
#   4. Run: cloud-init clean   (resets cloud-init so it runs on next boot)
#   5. Shut down the instance: shutdown -h now
#   6. Take a Vultr snapshot from the portal or CLI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_DEST="/root/run_benchmarks.sh"
SERVICE_DEST="/etc/systemd/system/bench-runner.service"

echo "=== Benchmark snapshot setup ==="

# ── Locate source files ──
# Accept files either from the repo (same dir as this script) or from /tmp
# (if scp'd separately).
find_file() {
    local name="$1"
    if [ -f "$SCRIPT_DIR/$name" ]; then
        echo "$SCRIPT_DIR/$name"
    elif [ -f "/tmp/$name" ]; then
        echo "/tmp/$name"
    else
        echo ""
    fi
}

RUNNER_SRC=$(find_file "bench_runner.sh")
SERVICE_SRC=$(find_file "bench-runner.service")

if [ -z "$RUNNER_SRC" ]; then
    echo "ERROR: bench_runner.sh not found in $SCRIPT_DIR or /tmp"
    echo "  scp bench_runner.sh root@<ip>:/tmp/ and retry"
    exit 1
fi

if [ -z "$SERVICE_SRC" ]; then
    echo "ERROR: bench-runner.service not found in $SCRIPT_DIR or /tmp"
    echo "  scp bench-runner.service root@<ip>:/tmp/ and retry"
    exit 1
fi

echo "Source files:"
echo "  Runner:  $RUNNER_SRC"
echo "  Service: $SERVICE_SRC"

# ── Install dependencies ──
echo ""
echo "Installing dependencies (at, jq)..."
apt-get update -qq
apt-get install -y -qq at jq
systemctl enable atd
systemctl start atd
echo "✓ at and jq installed"

# ── Verify existing tools ──
echo ""
echo "Verifying required tools..."
for tool in uv vultr git; do
    if command -v "$tool" &>/dev/null; then
        echo "  ✓ $tool: $(command -v "$tool")"
    else
        echo "  ✗ $tool: NOT FOUND — install this before snapshotting"
    fi
done

# ── Install runner script ──
echo ""
echo "Installing runner script to $RUNNER_DEST..."
cp "$RUNNER_SRC" "$RUNNER_DEST"
chmod 700 "$RUNNER_DEST"
echo "✓ Runner installed"

# ── Install systemd service ──
echo ""
echo "Installing systemd service to $SERVICE_DEST..."
cp "$SERVICE_SRC" "$SERVICE_DEST"
systemctl daemon-reload
systemctl enable bench-runner.service
echo "✓ Service installed and enabled"
echo "  Status: $(systemctl is-enabled bench-runner.service)"

# ── Vultr API key ──
echo ""
if grep -q "^VULTR_API_KEY=" /etc/environment 2>/dev/null; then
    echo "✓ VULTR_API_KEY already set in /etc/environment"
else
    echo "VULTR_API_KEY is not set in /etc/environment."
    echo "The runner needs it to self-destruct after benchmarks complete."
    echo ""
    read -r -p "Enter your Vultr API key (or press Enter to skip): " API_KEY
    if [ -n "$API_KEY" ]; then
        echo "VULTR_API_KEY=$API_KEY" >> /etc/environment
        echo "✓ VULTR_API_KEY written to /etc/environment"
    else
        echo "SKIPPED — you must add this manually before snapshotting:"
        echo "  echo 'VULTR_API_KEY=<your-key>' >> /etc/environment"
    fi
fi

# ── Reset cloud-init ──
echo ""
echo "Resetting cloud-init state (so it runs fresh on next boot)..."
cloud-init clean
echo "✓ cloud-init reset"

# ── Summary ──
echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Verify:  systemctl is-enabled bench-runner"
echo "  2. Verify:  ls -la $RUNNER_DEST"
echo "  3. Verify:  grep VULTR_API_KEY /etc/environment"
echo "  4. Shut down:  shutdown -h now"
echo "  5. Take snapshot from Vultr portal/CLI"
echo "  6. Update the snapshot ID in orchestrate_vultr.py"
echo ""
echo "To test before snapshotting (optional):"
echo "  Set a dummy userdata and run the script manually:"
echo "    export USERDATA_OVERRIDE='{\"models\":[\"test/model\"]}'"
echo "    bash $RUNNER_DEST"
