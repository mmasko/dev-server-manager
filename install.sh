#!/bin/bash
set -euo pipefail

# dev-server-manager installer for Amazon Linux (dnf)
# - Installs system dependencies (docker, git, unzip, cronie, iproute, curl)
# - Enables and starts docker and crond
# - Ensures dev-server-manager/check_connections.sh is executable
# - Installs a 5-minute system cron entry (/etc/cron.d/dev-server-manager) to run check_connections.sh as root
# - No sudo needed; intended for AWS User Data (runs as root)

TARGET_USER="${SUDO_USER:-$(id -un)}"
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
if [ -z "${HOME_DIR:-}" ]; then
  HOME_DIR="$(eval echo "~$TARGET_USER")"
fi
# Prefer the default Amazon Linux user when present (User Data runs as root)
if getent passwd ec2-user >/dev/null 2>&1; then
  TARGET_USER="ec2-user"
  HOME_DIR="/home/ec2-user"
fi

PROJECT_DIR="$HOME_DIR/projects/dev-server-manager"
SCRIPT_PATH="$PROJECT_DIR/check_connections.sh"
CRON_LINE="*/5 * * * * /bin/bash $SCRIPT_PATH"

echo "[dev-server-manager] Preparing system with dnf..."
dnf -qy update || true
dnf -qy upgrade || true
dnf -qy install docker git unzip cronie iproute curl || true

echo "[dev-server-manager] Enabling services (docker, crond)..."
systemctl enable --now docker || true
systemctl enable --now crond || true

echo "[dev-server-manager] Adding $TARGET_USER to docker group (idempotent)..."
usermod -aG docker "$TARGET_USER" || true

if ! command -v docker-compose >/dev/null 2>&1; then
  echo "[dev-server-manager] Installing docker-compose..."
  curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
else
  echo "[dev-server-manager] docker-compose already present"
fi

echo "[dev-server-manager] Ensuring project directory exists: $PROJECT_DIR"
mkdir -p "$PROJECT_DIR"

# Generate .gitignore from Toptal API (idempotent)
# Reference: https://www.toptal.com/developers/gitignore/api/batch,terraform,linux,powershell,python
GITIGNORE_URL="https://www.toptal.com/developers/gitignore/api/batch,terraform,linux,powershell,python"
GITIGNORE_PATH="$PROJECT_DIR/.gitignore"
if [ ! -f "$GITIGNORE_PATH" ]; then
  echo "[dev-server-manager] Creating .gitignore via Toptal API at $GITIGNORE_PATH"
  if ! curl -fsSL "$GITIGNORE_URL" -o "$GITIGNORE_PATH"; then
    echo "[dev-server-manager] WARNING: Failed to fetch .gitignore from API, writing placeholder"
    echo "# .gitignore generation failed. You can manually fetch from $GITIGNORE_URL" > "$GITIGNORE_PATH"
  fi
  chown "$TARGET_USER":"$TARGET_USER" "$GITIGNORE_PATH" || true
else
  echo "[dev-server-manager] .gitignore already exists at $GITIGNORE_PATH; leaving as-is"
fi

# Ensure additional Terraform ignore rules appended (idempotent)
if [ -f "$GITIGNORE_PATH" ]; then
  if ! grep -Fq "# dev-server-manager: terraform ignore rules" "$GITIGNORE_PATH"; then
    {
      echo "";
      echo "# dev-server-manager: terraform ignore rules";
      echo "*.tf*";
      echo "!*.tf";
    } >> "$GITIGNORE_PATH"
    chown "$TARGET_USER":"$TARGET_USER" "$GITIGNORE_PATH" || true
    echo "[dev-server-manager] Appended Terraform ignore rules to $GITIGNORE_PATH"
  else
    echo "[dev-server-manager] Terraform ignore rules already present in $GITIGNORE_PATH"
  fi
fi

# Adjust PROJECT_DIR/SCRIPT_PATH if repository exists under /home/ec2-user
if [ ! -f "$SCRIPT_PATH" ] && [ -f "/home/ec2-user/projects/dev-server-manager/check_connections.sh" ]; then
  PROJECT_DIR="/home/ec2-user/projects/dev-server-manager"
  SCRIPT_PATH="$PROJECT_DIR/check_connections.sh"
fi

if [ ! -f "$SCRIPT_PATH" ]; then
  echo "[dev-server-manager] ERROR: Expected script not found at $SCRIPT_PATH"
  echo "[dev-server-manager] Ensure the repo is cloned at $PROJECT_DIR and rerun this installer."
  exit 1
fi

echo "[dev-server-manager] Setting ownership and executable bit on $SCRIPT_PATH"
chown "$TARGET_USER":"$TARGET_USER" "$SCRIPT_PATH" || true
chmod +x "$SCRIPT_PATH"

# Cron runs as root from /etc/cron.d; no sudoers modifications required

# Install system cron via /etc/cron.d (idempotent)
echo "[dev-server-manager] Installing 5-min system cron in /etc/cron.d/dev-server-manager..."
CRON_FILE="/etc/cron.d/dev-server-manager"
cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /bin/bash $SCRIPT_PATH >> /var/log/dev-server-manager.cron.log 2>&1
EOF
chmod 644 "$CRON_FILE"
echo "[dev-server-manager] System cron installed at $CRON_FILE"

echo "[dev-server-manager] Installation complete."