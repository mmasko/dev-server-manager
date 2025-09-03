#!/bin/bash
set -euo pipefail

# dev-server-manager installer for Amazon Linux (dnf)
# - Installs system dependencies (docker, git, unzip, cronie, iproute)
# - Enables and starts docker and crond
# - Ensures dev-server-manager/check_connections.sh is executable
# - Installs a 5-minute user crontab entry to run check_connections.sh
# - Grants $TARGET_USER passwordless permission to shutdown for cron

TARGET_USER="${SUDO_USER:-$(id -un)}"
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
if [ -z "${HOME_DIR:-}" ]; then
  HOME_DIR="$(eval echo "~$TARGET_USER")"
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

if [ ! -f "$SCRIPT_PATH" ]; then
  echo "[dev-server-manager] ERROR: Expected script not found at $SCRIPT_PATH"
  echo "[dev-server-manager] Ensure the repo is cloned at $PROJECT_DIR and rerun this installer."
  exit 1
fi

echo "[dev-server-manager] Setting ownership and executable bit on $SCRIPT_PATH"
chown "$TARGET_USER":"$TARGET_USER" "$SCRIPT_PATH" || true
chmod +x "$SCRIPT_PATH"

# Allow shutdown without password for the cron-executed user
if [ "$(id -u)" -eq 0 ]; then
  SUDOERS_FILE="/etc/sudoers.d/dev-server-manager"
  if ! grep -q "$TARGET_USER" "$SUDOERS_FILE" 2>/dev/null; then
    echo "$TARGET_USER ALL=(root) NOPASSWD: /sbin/shutdown, /usr/sbin/shutdown, /bin/systemctl poweroff, /usr/bin/systemctl poweroff" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    echo "[dev-server-manager] Configured sudoers drop-in: $SUDOERS_FILE"
  else
    echo "[dev-server-manager] Sudoers drop-in already configured"
  fi
fi

# Install cron job for TARGET_USER without duplicates
echo "[dev-server-manager] Installing 5-min cron job for $TARGET_USER (idempotent)..."
if [ "$(id -u)" -eq 0 ]; then
  EXISTING="$(crontab -u "$TARGET_USER" -l 2>/dev/null || true)"
  if ! printf "%s\n" "$EXISTING" | grep -Fq "$SCRIPT_PATH"; then
    printf "%s\n%s\n" "$EXISTING" "$CRON_LINE" | crontab -u "$TARGET_USER" -
    echo "[dev-server-manager] Cron job installed for $TARGET_USER"
  else
    echo "[dev-server-manager] Cron job already present for $TARGET_USER"
  fi
else
  EXISTING="$(crontab -l 2>/dev/null || true)"
  if ! printf "%s\n" "$EXISTING" | grep -Fq "$SCRIPT_PATH"; then
    printf "%s\n%s\n" "$EXISTING" "$CRON_LINE" | crontab -
    echo "[dev-server-manager] Cron job installed for $TARGET_USER"
  else
    echo "[dev-server-manager] Cron job already present for $TARGET_USER"
  fi
fi

echo "[dev-server-manager] Installation complete."