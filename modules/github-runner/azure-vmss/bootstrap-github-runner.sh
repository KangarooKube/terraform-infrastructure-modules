#!/bin/bash
#
# bootstrap-github-runner.sh — runs once on each new VMSS instance via cloud-init.
#
# Idempotent:
#   - Docker install is skipped if already present.
#   - GitHub Actions runner uses --replace so re-registering with the same name
#     overwrites the previous registration.
#
# Required environment (sourced from /opt/gh-runner/runner.env):
#   GH_REPO            — full HTTPS URL of the repo
#   GH_RUNNER_TOKEN    — registration token (1-hour TTL)
#   RUNNER_LABELS      — comma-separated custom labels (e.g. "gh-runner-azure")
#   RUNNER_NAME        — runner name (defaults to gh-runner-runner-<hostname>)
#   RUNNER_VERSION     — actions-runner release version (e.g. 2.338.2)
#   RUNNER_USER        — local user that owns and runs the runner (e.g. azureuser)
#   EXTRA_APT_PACKAGES — optional space-separated apt packages
#   JOB_CLEANUP_ENABLED — "true" installs the job-started/job-completed hooks
#
# Optional /opt/gh-runner/extra-bootstrap.sh runs as root before registration.
#
set -euo pipefail

LOG_FILE="/var/log/gh-runner-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== gh-runner bootstrap starting at $(date -u +%FT%TZ) ==="

ENV_FILE="/opt/gh-runner/runner.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found" >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

: "${GH_REPO:?GH_REPO not set}"
: "${GH_RUNNER_TOKEN:?GH_RUNNER_TOKEN not set}"
RUNNER_LABELS="${RUNNER_LABELS:-gh-runner-azure}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_VERSION="${RUNNER_VERSION:-2.338.2}"
RUNNER_USER="${RUNNER_USER:-azureuser}"
EXTRA_APT_PACKAGES="${EXTRA_APT_PACKAGES:-}"
JOB_CLEANUP_ENABLED="${JOB_CLEANUP_ENABLED:-true}"
DOCKER_VERSION="${DOCKER_VERSION:-5:27.5.1-1~ubuntu.24.04~noble}"

# ----- Base packages ---------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release jq sudo tar \
  git git-lfs python3 python3-venv python3-pip openssl \
  unzip zip wget rsync xz-utils zstd build-essential
if [[ -n "$EXTRA_APT_PACKAGES" ]]; then
  echo "Installing extra apt packages: $EXTRA_APT_PACKAGES"
  # shellcheck disable=SC2086
  apt-get install -y --no-install-recommends $EXTRA_APT_PACKAGES
fi

# ----- Docker (idempotent) ---------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -y --allow-downgrades \
    docker-ce="${DOCKER_VERSION}" \
    docker-ce-cli="${DOCKER_VERSION}" \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
else
  echo "Docker already installed: $(docker --version)"
fi

mkdir -p /etc/docker
echo '{"max-concurrent-downloads": 32}' > /etc/docker/daemon.json
systemctl enable --now docker
systemctl restart docker

# Ensure the runner user exists and is in the docker group
if ! id "$RUNNER_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$RUNNER_USER"
fi
usermod -aG docker "$RUNNER_USER"

SUDOERS_FILE="/etc/sudoers.d/90-${RUNNER_USER}-nopasswd"
SUDOERS_TMP="$(mktemp)"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$RUNNER_USER" > "$SUDOERS_TMP"
if visudo -c -f "$SUDOERS_TMP" >/dev/null; then
  install -m 0440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
  echo "Installed passwordless sudo at $SUDOERS_FILE"
else
  echo "ERROR: visudo refused generated sudoers fragment for $RUNNER_USER" >&2
  rm -f "$SUDOERS_TMP"
  exit 1
fi
rm -f "$SUDOERS_TMP"

EXTRA_SCRIPT="/opt/gh-runner/extra-bootstrap.sh"
if [[ -s "$EXTRA_SCRIPT" ]]; then
  echo "Running extra bootstrap script $EXTRA_SCRIPT..."
  bash "$EXTRA_SCRIPT"
fi

# ----- GitHub Actions runner -------------------------------------------------
RUNNER_HOME="/home/${RUNNER_USER}/actions-runner"
RUNNER_WORK_DIR="${RUNNER_HOME}/_work"
HOOK_DIR="/opt/gh-runner/hooks"
RUNNER_TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TARBALL}"

mkdir -p "$RUNNER_HOME"
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"

if [[ ! -f "${RUNNER_HOME}/config.sh" ]]; then
  echo "Downloading GitHub Actions runner v${RUNNER_VERSION}..."
  sudo -u "$RUNNER_USER" -H bash -c "cd '$RUNNER_HOME' && curl -fsSLo '$RUNNER_TARBALL' '$RUNNER_URL' && tar xzf '$RUNNER_TARBALL' && rm -f '$RUNNER_TARBALL'"
fi

# Stop and uninstall any prior systemd service so we can register cleanly.
SVC_NAME="$(ls /etc/systemd/system/actions.runner.*.service 2>/dev/null | head -1 || true)"
if [[ -n "$SVC_NAME" ]]; then
  echo "Removing prior runner service: $SVC_NAME"
  ( cd "$RUNNER_HOME" && ./svc.sh stop || true )
  ( cd "$RUNNER_HOME" && ./svc.sh uninstall || true )
fi

# Best-effort de-register if a previous .runner config is present.
if [[ -f "${RUNNER_HOME}/.runner" ]]; then
  echo "Removing prior runner registration (best effort)..."
  sudo -u "$RUNNER_USER" -H bash -c "cd '$RUNNER_HOME' && ./config.sh remove --token '$GH_RUNNER_TOKEN'" || true
fi

echo "Registering runner: name=${RUNNER_NAME}, labels=${RUNNER_LABELS}, repo=${GH_REPO}"
sudo -u "$RUNNER_USER" -H bash -c "cd '$RUNNER_HOME' && ./config.sh \
  --unattended \
  --replace \
  --url '$GH_REPO' \
  --token '$GH_RUNNER_TOKEN' \
  --name '$RUNNER_NAME' \
  --labels '$RUNNER_LABELS' \
  --runnergroup default \
  --work _work"

# Job hooks run as the runner user via `bash -e`; they log and always exit 0 so
# a cleanup problem never fails a job.
install -d -m 0755 -o root -g root "$HOOK_DIR"
printf 'WORK_DIR=%q\n' "$RUNNER_WORK_DIR" > "$HOOK_DIR/common.sh"
cat >> "$HOOK_DIR/common.sh" <<'EOF'
log() { echo "[gh-runner-cleanup] $*" >&2; }

# Prints the resolved job workspace, or fails if it is empty or not strictly
# beneath the runner work directory.
resolve_workspace() {
  local ws="${GITHUB_WORKSPACE:-}" root real
  if [[ -z "$ws" ]]; then
    log "GITHUB_WORKSPACE is empty; skipping workspace cleanup"
    return 1
  fi
  root="$(realpath -m -- "$WORK_DIR")"
  if ! real="$(realpath -m -- "$ws")"; then
    log "cannot resolve '$ws'; skipping workspace cleanup"
    return 1
  fi
  if [[ -z "$root" || "$root" == "/" || "$real" != "$root"/?* ]]; then
    log "refusing to clean '$real': not strictly beneath '$root'"
    return 1
  fi
  printf '%s\n' "$real"
}
EOF
cat > "$HOOK_DIR/job-started.sh" <<'EOF'
#!/bin/bash
set +e +o pipefail
. /opt/gh-runner/hooks/common.sh
if ws="$(resolve_workspace)" && [[ -d "$ws" ]]; then
  sudo -n chown -R -h "$(id -u):$(id -g)" -- "$ws" || log "failed to take ownership of '$ws'"
fi
exit 0
EOF
cat > "$HOOK_DIR/job-completed.sh" <<'EOF'
#!/bin/bash
set +e +o pipefail
. /opt/gh-runner/hooks/common.sh
if command -v docker >/dev/null 2>&1; then
  if ids="$(docker ps -aq)"; then
    if [[ -n "$ids" ]]; then
      # shellcheck disable=SC2086
      docker rm -f $ids >/dev/null || log "docker rm -f failed"
    fi
  else
    log "docker ps failed; skipping container cleanup"
  fi
  docker network prune -f >/dev/null || log "docker network prune failed"
  docker volume prune -f >/dev/null || log "docker volume prune failed"
fi
if ws="$(resolve_workspace)" && [[ -d "$ws" ]]; then
  sudo -n find "$ws" -mindepth 1 -delete || log "failed to fully clean '$ws'"
fi
exit 0
EOF
chmod 0644 "$HOOK_DIR/common.sh"
chmod 0755 "$HOOK_DIR/job-started.sh" "$HOOK_DIR/job-completed.sh"

# config.sh (re)writes .env; replace any prior hook lines.
RUNNER_DOTENV="${RUNNER_HOME}/.env"
touch "$RUNNER_DOTENV"
sed -i '/^ACTIONS_RUNNER_HOOK_JOB_/d' "$RUNNER_DOTENV"
if [[ "$JOB_CLEANUP_ENABLED" == "true" ]]; then
  echo "Enabling job cleanup hooks"
  printf 'ACTIONS_RUNNER_HOOK_JOB_STARTED=%s\nACTIONS_RUNNER_HOOK_JOB_COMPLETED=%s\n' \
    "$HOOK_DIR/job-started.sh" "$HOOK_DIR/job-completed.sh" >> "$RUNNER_DOTENV"
fi
chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DOTENV"

echo "Installing runner as systemd service..."
( cd "$RUNNER_HOME" && ./svc.sh install "$RUNNER_USER" )
( cd "$RUNNER_HOME" && ./svc.sh start )

echo "=== gh-runner bootstrap complete at $(date -u +%FT%TZ) ==="
systemctl status "actions.runner.*" --no-pager || true
