#!/usr/bin/env bash
# setup.sh - DirectAdmin partner installer bootstrap
# - Verify checksum if EXPECTED_SHA256 is provided
# - Auto-detect network iface, add alias (temp + NM persistent)
# - Optionally download and run a custom installer if CUSTOM_INSTALLER_URL set
#
# Edit CONFIG section below before running or export env vars.
set -euo pipefail

# ---------------------- CONFIG (edit or export env vars) -------------------
# If you have a local license file, set LOCAL_LICENSE_PATH to its path.
# Example: export LOCAL_LICENSE_PATH="/root/license.key"
LOCAL_LICENSE_PATH="${LOCAL_LICENSE_PATH:-}"

# Default partner license URL (official partner location)
DEFAULT_LICENSE_URL="https://raw.githubusercontent.com/tuyenht/da-1.62.4/refs/heads/main/license.key"
# You can override by exporting LICENSE_URL before running.
LICENSE_URL="${LICENSE_URL:-$DEFAULT_LICENSE_URL}"

# If you want to verify license integrity supply EXPECTED_SHA256 via env
# Example: export EXPECTED_SHA256="ab12...".
EXPECTED_SHA256="${EXPECTED_SHA256:-}"

# IP alias to add (leave empty to skip)
ALIAS_IP="${ALIAS_IP:-176.99.3.34}"
ALIAS_PREFIX="${ALIAS_PREFIX:-32}"   # recommended 32 or 24; avoid /8 unless your hoster requires it

# Custom installer URL (partner-provided). If empty, script will skip installer step.
# Must be HTTPS for safety (script will ask to continue if not HTTPS).
CUSTOM_INSTALLER_URL="${CUSTOM_INSTALLER_URL:-}"

# Non-interactive mode? 1 = assume yes for confirmations (use with caution), 0 = interactive
NONINTERACTIVE="${NONINTERACTIVE:-0}"

# Skip firewall auto config? 1 = skip, 0 = configure
SKIP_FIREWALL="${SKIP_FIREWALL:-0}"
# -----------------------------------------------------------------------------

bail() { echo "ERROR: $*" >&2; exit 1; }
confirm() {
  if [ "${NONINTERACTIVE}" = "1" ]; then
    return 0
  fi
  read -rp "$1 [y/N]: " ans
  case "$ans" in [yY]|[yY][eE][sS]) return 0;; *) return 1;; esac
}

# Must be root
if [ "$(id -u)" -ne 0 ]; then
  bail "Script must be run as root (sudo)."
fi

echo "===== DirectAdmin partner setup bootstrap ====="
echo "LOCAL_LICENSE_PATH: ${LOCAL_LICENSE_PATH:-<none>}"
echo "LICENSE_URL (will be used if no local file): ${LICENSE_URL:-<none>}"
[ -n "$EXPECTED_SHA256" ] && echo "EXPECTED_SHA256: (provided)" || echo "EXPECTED_SHA256: (not provided)"
echo "ALIAS_IP: ${ALIAS_IP:-<none>}, ALIAS_PREFIX: ${ALIAS_PREFIX:-<none>}"
echo "CUSTOM_INSTALLER_URL: ${CUSTOM_INSTALLER_URL:-<none>}"
echo "NONINTERACTIVE=${NONINTERACTIVE}, SKIP_FIREWALL=${SKIP_FIREWALL}"
echo "==============================================="

# helper
download_file() {
  local url="$1"; local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --max-time 120 "$url" -o "$out"
  else
    wget -qO "$out" "$url"
  fi
}

# ---- Step A: prepare basic packages ----
echo "[Step A] Installing prerequisites (NetworkManager, curl, iproute, firewalld)..."
dnf -y makecache >/dev/null 2>&1 || true
dnf -y install -y curl wget iproute NetworkManager firewalld perl policycoreutils-python-utils >/dev/null 2>&1 || true

# Optional: set SELinux to permissive now to avoid install issues (non-destructive)
if command -v getenforce >/dev/null 2>&1; then
  SELSTAT="$(getenforce || true)"
  echo "[Info] SELinux mode: $SELSTAT"
  if [ "$SELSTAT" = "Enforcing" ]; then
    echo "[Info] Temporarily set SELinux to permissive to avoid install-time denials."
    setenforce 0 || true
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config || true
  fi
fi

# ---- Step B: detect interface + NM connection ----
echo "[Step B] Detecting primary network interface (used for outbound connections)..."
IFACE="$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')"
if [ -z "$IFACE" ]; then
  IFACE="$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: '$2=="connected"{print $1; exit}')"
fi
if [ -z "$IFACE" ]; then
  IFACE="$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1)"
fi
[ -n "$IFACE" ] || bail "Cannot auto-detect network interface; set IFACE manually and rerun."

echo "[Info] Chosen interface: $IFACE"

CONN=""
if command -v nmcli >/dev/null 2>&1; then
  CONN="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v IF="$IFACE" '$2==IF{print $1; exit}')"
  if [ -z "$CONN" ]; then
    CONN="$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v IF="$IFACE" '$2==IF{print $1; exit}')"
  fi
fi
echo "[Info] NetworkManager connection: ${CONN:-<none>}"

# ---- Step C: add alias IP (if ALIAS_IP set) ----
if [ -n "${ALIAS_IP:-}" ]; then
  echo "[Step C] Adding alias IP ${ALIAS_IP}/${ALIAS_PREFIX} to ${IFACE} (temporary then persistent)."
  ip addr add "${ALIAS_IP}/${ALIAS_PREFIX}" dev "$IFACE" || echo "[Warn] ip addr add may have failed / already exists."

  if [ -n "$CONN" ]; then
    echo "[Info] Appending IP to NM connection $CONN"
    nmcli connection modify "$CONN" +ipv4.addresses "${ALIAS_IP}/${ALIAS_PREFIX}" || echo "[Warn] nmcli modify returned non-zero"
    # avoid changing default route
    nmcli connection modify "$CONN" ipv4.never-default yes || true
    nmcli connection up "$CONN" || true
  else
    echo "[Info] No existing NM connection found for $IFACE - creating one: alias-${ALIAS_IP}"
    nmcli connection add type ethernet ifname "$IFACE" con-name "alias-${ALIAS_IP}" ipv4.addresses "${ALIAS_IP}/${ALIAS_PREFIX}" ipv4.method manual || true
    nmcli connection up "alias-${ALIAS_IP}" || true
    CONN="alias-${ALIAS_IP}"
  fi
fi

# ---- Step D: firewall ----
if [ "${SKIP_FIREWALL}" != "1" ]; then
  echo "[Step D] Ensure firewalld running and open DirectAdmin ports (2222,80,443)"
  systemctl enable --now firewalld || true
  firewall-cmd --permanent --add-port=2222/tcp || true
  firewall-cmd --permanent --add-service=http || true
  firewall-cmd --permanent --add-service=https || true
  firewall-cmd --reload || true
else
  echo "[Step D] SKIP_FIREWALL set - skipping firewall changes"
fi

# ---- Step E: obtain license.key ----
TARGET_LICENSE="/usr/local/directadmin/conf/license.key"
TMP_LICENSE="/tmp/license.key.$$"

echo "[Step E] Preparing license.key ..."
if [ -n "$LOCAL_LICENSE_PATH" ] && [ -f "$LOCAL_LICENSE_PATH" ]; then
  echo "[Info] Using local license file: $LOCAL_LICENSE_PATH"
  cp -f "$LOCAL_LICENSE_PATH" "$TMP_LICENSE"
else
  echo "[Info] No local license provided. Will attempt to download from LICENSE_URL: $LICENSE_URL"
  # enforce HTTPS for remote download
  if ! echo "$LICENSE_URL" | grep -qE '^https://'; then
    echo "[Warning] LICENSE_URL is not HTTPS: $LICENSE_URL"
    confirm "Continue to download license from non-HTTPS URL?" || bail "Cancelled by user."
  fi

  # require checksum if not interactive (safer), but allow proceed after confirm
  if [ -z "$EXPECTED_SHA256" ] && [ "$NONINTERACTIVE" = "1" ]; then
    bail "EXPECTED_SHA256 must be supplied in non-interactive mode for remote downloads."
  fi

  echo "[Info] Downloading license from: $LICENSE_URL"
  download_file "$LICENSE_URL" "$TMP_LICENSE" || bail "Failed to download license from $LICENSE_URL"

  if [ -n "$EXPECTED_SHA256" ]; then
    echo "[Info] Verifying license SHA256..."
    actual="$(sha256sum "$TMP_LICENSE" | awk '{print $1}')"
    if [ "$actual" != "$EXPECTED_SHA256" ]; then
      rm -f "$TMP_LICENSE"
      bail "SHA256 mismatch for downloaded license (expected $EXPECTED_SHA256, got $actual)"
    fi
    echo "[Info] SHA256 OK."
  else
    echo "[Warn] No EXPECTED_SHA256 provided. You should verify the license file manually."
    confirm "Preview license and continue to install it?" || { rm -f "$TMP_LICENSE"; bail "Aborted by user"; }
  fi
fi

# Place license into final target atomically
echo "[Info] Installing license to $TARGET_LICENSE"
mkdir -p "$(dirname "$TARGET_LICENSE")"
mv -f "$TMP_LICENSE" "$TARGET_LICENSE"
chmod 600 "$TARGET_LICENSE"
chown diradmin:diradmin "$TARGET_LICENSE" || echo "[Warn] Could not chown diradmin:diradmin (user/group may not exist)"

# ---- Step F: update directadmin.conf ethernet_dev (if present) ----
DA_CONF="/usr/local/directadmin/conf/directadmin.conf"
if [ -f "$DA_CONF" ]; then
  echo "[Step F] Update directadmin.conf ethernet_dev -> $IFACE"
  if grep -q '^ethernet_dev=' "$DA_CONF"; then
    /usr/bin/perl -pi -e "s/^ethernet_dev=.*/ethernet_dev=${IFACE}/" "$DA_CONF" || true
  else
    echo "ethernet_dev=${IFACE}" >> "$DA_CONF"
  fi
else
  echo "[Info] directadmin.conf not present yet - installer likely hasn't created it. Will skip for now."
fi

# ---- Step G: optional - download & run custom installer if provided ----
if [ -n "$CUSTOM_INSTALLER_URL" ]; then
  echo "[Step G] Custom installer URL set: $CUSTOM_INSTALLER_URL"
  if ! echo "$CUSTOM_INSTALLER_URL" | grep -qE '^https?://'; then
    bail "CUSTOM_INSTALLER_URL must start with http:// or https://"
  fi

  if ! echo "$CUSTOM_INSTALLER_URL" | grep -qE '^https://'; then
    echo "[Warning] CUSTOM_INSTALLER_URL is not HTTPS."
    confirm "Continue to download and run installer from a non-HTTPS URL?" || bail "Cancelled by user."
  fi

  TMP_INSTALLER="/tmp/da_installer_$(date +%s).sh"
  echo "[Info] Downloading installer to $TMP_INSTALLER (preview first)"
  download_file "$CUSTOM_INSTALLER_URL" "$TMP_INSTALLER" || bail "Failed to download installer from $CUSTOM_INSTALLER_URL"
  chmod +x "$TMP_INSTALLER"

  echo "---- installer preview (first 60 lines) ----"
  sed -n '1,60p' "$TMP_INSTALLER" || true
  echo "---- end preview ----"
  confirm "Run the downloaded installer script now?" || bail "User cancelled running installer."

  echo "[Info] Running installer (may be interactive) ..."
  /bin/bash "$TMP_INSTALLER" || echo "[Warn] Installer exited with non-zero status - check logs"
else
  echo "[Info] No CUSTOM_INSTALLER_URL set - skipping installer run."
fi

# ---- Step H: restart directadmin service if present ----
echo "[Step H] Restart DirectAdmin service (if installed)"
if systemctl list-unit-files | grep -q '^directadmin'; then
  systemctl restart directadmin || true
  sleep 2
  systemctl status directadmin --no-pager -l || true
else
  echo "[Info] directadmin service not found - installer may not have created it yet."
fi

# ---- Final checks & notices ----
echo "===== FINISHED ====="
echo "Network iface: $IFACE"
if [ -n "${ALIAS_IP:-}" ]; then
  echo "Alias IP configured: ${ALIAS_IP}/${ALIAS_PREFIX}"
  ip addr show dev "$IFACE" | grep "${ALIAS_IP}" || true
fi
echo "License installed at: $TARGET_LICENSE"
ls -l "$TARGET_LICENSE" || true
echo "If DirectAdmin isn't running, check installer logs and /var/log/directadmin/*"

echo
echo "Rollback hints:"
echo "  # remove persistent alias:"
echo "  nmcli connection modify \"${CONN}\" -ipv4.addresses \"${ALIAS_IP}/${ALIAS_PREFIX}\" || true"
echo "  nmcli connection up \"${CONN}\" || true"
echo "  # remove temporary alias immediately:"
echo "  ip addr del ${ALIAS_IP}/${ALIAS_PREFIX} dev ${IFACE} || true"

exit 0
