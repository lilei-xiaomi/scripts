#!/bin/bash
# Bootstrap a fresh Vultr instance into a snapshot-ready benchmark runner.
#
# Run this on a FRESH Vultr instance (Ubuntu 22.04 or Debian Bookworm, root).
# It installs all dependencies, clones the benchmark repo, installs the runner
# service, writes credentials to /etc/environment, resets cloud-init, and shuts
# down so you can immediately take a snapshot.
#
# Usage (from your laptop):
#   scp scripts/bootstrap_instance.sh root@<ip>:/tmp/
#   ssh root@<ip> 'bash /tmp/bootstrap_instance.sh'
#
# You will be prompted interactively for:
#   - GitHub repo URL (or leave blank to use the default)
#   - OPENROUTER_API_KEY
#   - PINCHBENCH_TOKEN
#   - VULTR_API_KEY
#   - SLACK_WEBHOOK_URL (optional)
#
# After the script exits the instance will be shut down. Take a snapshot from
# the Vultr portal or with:
#   vultr snapshot create --instance-id <id> --description "bench-runner $(date +%Y-%m-%d)"
# Then update the snapshot ID in orchestrate_vultr.py and create_instance.sh.

set -euo pipefail

SKILL_DIR="/root/skill"
REPO_URL="https://github.com/pinchbench/skill.git"
LOG="/var/log/bootstrap.log"

exec > >(tee -a "$LOG") 2>&1

echo "=== PinchBench bootstrap started at $(date -u) ==="

# ── Prompt for credentials upfront ──
echo ""
echo "Enter credentials (all required unless noted):"
echo ""

read -r -p "Skill repo URL [$REPO_URL]: " INPUT_REPO
REPO_URL="${INPUT_REPO:-$REPO_URL}"

read -r -p "OPENROUTER_API_KEY: " OPENROUTER_API_KEY
if [ -z "$OPENROUTER_API_KEY" ]; then
    echo "ERROR: OPENROUTER_API_KEY is required"
    exit 1
fi

read -r -p "PINCHBENCH_TOKEN: " PINCHBENCH_TOKEN
if [ -z "$PINCHBENCH_TOKEN" ]; then
    echo "ERROR: PINCHBENCH_TOKEN is required"
    exit 1
fi

read -r -p "VULTR_API_KEY: " VULTR_API_KEY
if [ -z "$VULTR_API_KEY" ]; then
    echo "ERROR: VULTR_API_KEY is required (needed for instance self-destruct)"
    exit 1
fi

read -r -p "SLACK_WEBHOOK_URL (optional, press Enter to skip): " SLACK_WEBHOOK_URL

echo ""
echo "=== Starting installation ==="

# ── System packages ──
echo ""
echo "--- Installing system packages ---"
apt-get update -qq
apt-get install -y -qq \
    curl \
    git \
    jq \
    at \
    python3 \
    python3-pip \
    python3-venv \
    python3-yaml \
    python-is-python3 \
    ca-certificates \
    gnupg

systemctl enable atd
systemctl start atd
echo "✓ System packages installed"

# ── Node.js 22 ──
echo ""
echo "--- Installing Node.js 22 ---"
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs
echo "✓ Node.js $(node --version) installed"

# ── uv ──
echo ""
echo "--- Installing uv ---"
curl -LsSf https://astral.sh/uv/install.sh | sh
# Make available system-wide
ln -sf /root/.local/bin/uv /usr/local/bin/uv
echo "✓ uv $(uv --version) installed"

# ── Vultr CLI ──
echo ""
echo "--- Installing Vultr CLI ---"
# Download latest vultr-cli for Linux amd64
# Tag format is "v3.8.0"; asset filename uses the full tag: vultr-cli_v3.8.0_linux_amd64.tar.gz
# Binary inside the archive is named "vultr-cli"; we install it as both "vultr-cli" and "vultr"
# so both names work (orchestrate_vultr.py uses "vultr", bench_runner.sh uses "vultr")
VULTR_CLI_VERSION=$(curl -sf "https://api.github.com/repos/vultr/vultr-cli/releases/latest" | jq -r '.tag_name')
VULTR_CLI_URL="https://github.com/vultr/vultr-cli/releases/download/${VULTR_CLI_VERSION}/vultr-cli_${VULTR_CLI_VERSION}_linux_amd64.tar.gz"
echo "  Downloading vultr-cli $VULTR_CLI_VERSION..."
curl -sL "$VULTR_CLI_URL" | tar -xz -C /usr/local/bin vultr-cli
chmod +x /usr/local/bin/vultr-cli
# Symlink as "vultr" so existing scripts using either name work
ln -sf /usr/local/bin/vultr-cli /usr/local/bin/vultr
echo "✓ vultr-cli $(vultr-cli version) installed"

# ── OpenClaw ──
echo ""
echo "--- Installing OpenClaw ---"
npm install -g openclaw
echo "✓ OpenClaw $(openclaw --version 2>/dev/null || echo installed)"

# ── Clone benchmark repo ──
echo ""
echo "--- Cloning benchmark repo ---"
if [ -d "$SKILL_DIR" ]; then
    echo "  $SKILL_DIR already exists, pulling latest..."
    git -C "$SKILL_DIR" pull
else
    git clone "$REPO_URL" "$SKILL_DIR"
fi
echo "✓ Repo at $SKILL_DIR"

# ── Pre-install Python dependencies ──
echo ""
echo "--- Pre-installing Python dependencies ---"
cd "$SKILL_DIR"
uv sync --frozen
echo "✓ Python dependencies installed"

# ── Write credentials to /etc/environment ──
echo ""
echo "--- Writing credentials to /etc/environment ---"

# Remove any existing entries for these keys
sed -i '/^OPENROUTER_API_KEY=/d' /etc/environment
sed -i '/^PINCHBENCH_TOKEN=/d' /etc/environment
sed -i '/^VULTR_API_KEY=/d' /etc/environment
sed -i '/^SLACK_WEBHOOK_URL=/d' /etc/environment

cat >> /etc/environment <<EOF
OPENROUTER_API_KEY=$OPENROUTER_API_KEY
PINCHBENCH_TOKEN=$PINCHBENCH_TOKEN
VULTR_API_KEY=$VULTR_API_KEY
EOF

if [ -n "$SLACK_WEBHOOK_URL" ]; then
    echo "SLACK_WEBHOOK_URL=$SLACK_WEBHOOK_URL" >> /etc/environment
fi

# Also make available to login shells
cat > /etc/profile.d/pinchbench.sh <<EOF
export OPENROUTER_API_KEY=$OPENROUTER_API_KEY
export PINCHBENCH_TOKEN=$PINCHBENCH_TOKEN
export VULTR_API_KEY=$VULTR_API_KEY
EOF
if [ -n "$SLACK_WEBHOOK_URL" ]; then
    echo "export SLACK_WEBHOOK_URL=$SLACK_WEBHOOK_URL" >> /etc/profile.d/pinchbench.sh
fi

echo "✓ Credentials written"

# ── Install bench_runner.sh ──
echo ""
echo "--- Installing bench_runner.sh ---"
RUNNER_SRC=""
# Look relative to this script, then /tmp
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for candidate in "$SCRIPT_DIR/bench_runner.sh" "/tmp/bench_runner.sh"; do
    if [ -f "$candidate" ]; then
        RUNNER_SRC="$candidate"
        break
    fi
done

if [ -z "$RUNNER_SRC" ]; then
    echo "  bench_runner.sh not found locally — copying from repo..."
    # It lives in the pinchbench/scripts dir of the repo; if the skill repo
    # doesn't contain it, we embed a download path. For now, require it to
    # be scp'd alongside this script.
    echo "ERROR: bench_runner.sh not found in $SCRIPT_DIR or /tmp"
    echo "  scp scripts/bench_runner.sh root@<ip>:/tmp/ and rerun"
    exit 1
fi

cp "$RUNNER_SRC" /root/run_benchmarks.sh
chmod 700 /root/run_benchmarks.sh
echo "✓ Runner installed at /root/run_benchmarks.sh"

# ── Install bench-runner.service ──
echo ""
echo "--- Installing bench-runner.service ---"
SERVICE_SRC=""
for candidate in "$SCRIPT_DIR/bench-runner.service" "/tmp/bench-runner.service"; do
    if [ -f "$candidate" ]; then
        SERVICE_SRC="$candidate"
        break
    fi
done

if [ -z "$SERVICE_SRC" ]; then
    echo "ERROR: bench-runner.service not found in $SCRIPT_DIR or /tmp"
    echo "  scp scripts/bench-runner.service root@<ip>:/tmp/ and rerun"
    exit 1
fi

cp "$SERVICE_SRC" /etc/systemd/system/bench-runner.service
systemctl daemon-reload
systemctl enable bench-runner.service
echo "✓ Service installed and enabled ($(systemctl is-enabled bench-runner.service))"

# ── Reset cloud-init ──
echo ""
echo "--- Resetting cloud-init ---"
cloud-init clean
echo "✓ cloud-init reset"

# ── Verification ──
echo ""
echo "=== Verification ==="
echo -n "  uv:               "; uv --version
echo -n "  node:             "; node --version
echo -n "  vultr:            "; vultr-cli version
echo -n "  jq:               "; jq --version
echo -n "  at:               "; at -V 2>&1 || true
echo -n "  openclaw:         "; openclaw --version 2>/dev/null || echo "(check manually)"
echo -n "  runner script:    "; ls -la /root/run_benchmarks.sh
echo -n "  service enabled:  "; systemctl is-enabled bench-runner.service
echo -n "  repo:             "; git -C "$SKILL_DIR" log -1 --oneline
echo ""
echo "Credentials set:"
grep -E "OPENROUTER_API_KEY|PINCHBENCH_TOKEN|VULTR_API_KEY|SLACK_WEBHOOK_URL" /etc/environment \
    | sed 's/=.*/=<set>/'

echo ""
echo "=== Bootstrap complete at $(date -u) ==="
echo ""
echo "Next steps:"
echo "  1. Instance is shutting down now"
echo "  2. Take snapshot:"
echo "       vultr snapshot create --instance-id <id> --description \"bench-runner $(date +%Y-%m-%d)\""
echo "  3. Note the new snapshot ID and update in:"
echo "       orchestrate_vultr.py  (VultrConfig.snapshot default)"
echo "       create_instance.sh    (--snapshot flag)"
echo ""

# ── Shutdown ──
echo "Shutting down in 5 seconds..."
sleep 5
shutdown -h now
