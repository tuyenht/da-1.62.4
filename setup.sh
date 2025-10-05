#!/usr/bin/env bash
set -euo pipefail

# ----------------- CONFIG - PLEASE EDIT BEFORE RUNNING -----------------
# 1) Installer URL supplied by partner/vendor (MUST set; must be https ideally)
CUSTOM_INSTALLER_URL=""   # e.g. "https://partner.example.com/custom_setup.sh"
# 2) If you already have a license.key file on disk (legal), set path here (optional)
LOCAL_LICENSE_PATH=""     # e.g. "/root/license.key"
# 3) IP alias to add (leave empty if not needed)
ALIAS_IP="176.99.3.34"
ALIAS_PREFIX="32"         # recommended /32 or /24; keep as partner instructed (avoid /8 unless hoster requires)
# 4) If you want script to auto-reboot NetworkManager if required (be careful on remote SSH)
RESTART_NM_IF_MISMATCH=1  # 1=yes, 0=no
# 5) Skip firewall automatic config? (0 = configure, 1 = skip)
SKIP_FIREWALL=0
# 6) Non-interactive mode? (0 interactive confirmations; 1 = assume yes)
NONINTERACTIVE=0
# ----------------------------------------------------------------------

bail(){ echo "ERROR: $*" >&2; exit 1; }
confirm(){
  if [ "$NONINTERACTIVE" -eq 1 ]; then return 0; fi
  read -rp "$1 [y/N]: " ans
  case "$ans" in [yY]|[yY][eE][sS]) return 0;; *) return 1;; esac
}

if [ "$(id -u)" -ne 0 ]; then
  bail "Script phải chạy quyền root (sudo)."
fi

# safety: do not allow empty installer URL
if [ -z "${CUSTOM_INSTALLER_URL:-}" ]; then
  bail "Bạn phải đặt CUSTOM_INSTALLER_URL trong phần CONFIG trước khi chạy."
fi

echo "=== DirectAdmin Partner installer automation ==="
echo "Installer URL: $CUSTOM_INSTALLER_URL"
[ -n "${LOCAL_LICENSE_PATH:-}" ] && echo "Local license: $LOCAL_LICENSE_PATH" || echo "No local license path set"

# Basic URL sanity: require https OR ask confirmation if http
if ! echo "$CUSTOM_INSTALLER_URL" | grep -qE '^https://'; then
  echo "WARNING: Installer URL không phải HTTPS."
  confirm "Bạn có chắc muốn tiếp tục với URL không dùng HTTPS? (rủi ro MITM)" || bail "Hủy theo yêu cầu."
fi

# Check connectivity to installer URL (HEAD) before proceeding
echo "[*] Kiểm tra kết nối tới installer URL..."
if command -v curl >/dev/null 2>&1; then
  if ! curl -fsSIL --max-time 20 "$CUSTOM_INSTALLER_URL" >/dev/null 2>&1; then
    bail "Không thể kết nối/HEAD tới $CUSTOM_INSTALLER_URL. Kiểm tra URL và mạng."
  fi
else
  if ! wget --spider -q --tries=1 --timeout=20 "$CUSTOM_INSTALLER_URL"; then
    bail "Không thể kết nối tới $CUSTOM_INSTALLER_URL (vì không có curl/wget)."
  fi
fi
echo "[OK] Installer URL reachable."

# 1) Update minimal packages & install prerequisites
echo "[*] Cập nhật hệ thống và cài công cụ cần thiết..."
dnf -y makecache
dnf -y install -y wget curl perl iproute NetworkManager firewalld policycoreutils-python-utils || true

# 2) SELinux - set to permissive for install (configurable)
if command -v getenforce >/dev/null 2>&1; then
  SELSTAT=$(getenforce || true)
  echo "[*] SELinux mode: $SELSTAT"
  if [ "$SELSTAT" = "Enforcing" ]; then
    echo "[*] Tạm đặt SELinux sang permissive để tránh lỗi cài đặt (sửa lại sau)."
    setenforce 0 || true
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config || true
  fi
fi

# 3) Detect interface used for outbound traffic
echo "[*] Detect interface outbound..."
IFACE="$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')"
if [ -z "$IFACE" ]; then
  IFACE="$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: '$2=="connected"{print $1; exit}')"
fi
if [ -z "$IFACE" ]; then
  IFACE="$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1)"
fi
[ -n "$IFACE" ] || bail "Không thể detect interface tự động. Dừng."

echo "[*] Chosen interface: $IFACE"

# 4) Identify NM connection
CONN=""
if command -v nmcli >/dev/null 2>&1; then
  CONN="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v IF="$IFACE" '$2==IF{print $1; exit}')"
  if [ -z "$CONN" ]; then
    CONN="$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v IF="$IFACE" '$2==IF{print $1; exit}')"
  fi
fi
echo "[*] NetworkManager connection: ${CONN:-<none>}"

# 5) Add alias IP (if provided)
if [ -n "${ALIAS_IP:-}" ]; then
  echo "[*] Adding alias IP ${ALIAS_IP}/${ALIAS_PREFIX} to $IFACE (temporary)"
  ip addr add "${ALIAS_IP}/${ALIAS_PREFIX}" dev "$IFACE" || echo "Note: ip add may have existed or failed"

  if [ -n "$CONN" ]; then
    echo "[*] Append persistent IP to NM connection $CONN"
    nmcli connection modify "$CONN" +ipv4.addresses "${ALIAS_IP}/${ALIAS_PREFIX}" || echo "Warning: nmcli modify returned non-zero"
    # avoid default route change
    nmcli connection modify "$CONN" ipv4.never-default yes || true
    nmcli connection up "$CONN" || true
  else
    echo "[*] No NM connection found - creating new connection alias-${ALIAS_IP}"
    nmcli connection add type ethernet ifname "$IFACE" con-name "alias-${ALIAS_IP}" ipv4.addresses "${ALIAS_IP}/${ALIAS_PREFIX}" ipv4.method manual || true
    nmcli connection up "alias-${ALIAS_IP}" || true
    CONN="alias-${ALIAS_IP}"
  fi
fi

# 6) Firewall
if [ "$SKIP_FIREWALL" -eq 0 ]; then
  echo "[*] Ensure firewalld running and open ports 2222/http/https"
  systemctl enable --now firewalld || true
  firewall-cmd --permanent --add-port=2222/tcp || true
  firewall-cmd --permanent --add-service=http || true
  firewall-cmd --permanent --add-service=https || true
  firewall-cmd --reload || true
fi

# 7) Prepare license (copy local if provided)
if [ -n "${LOCAL_LICENSE_PATH:-}" ]; then
  if [ -f "$LOCAL_LICENSE_PATH" ]; then
    echo "[*] Copy local license to /usr/local/directadmin/conf/license.key"
    mkdir -p /usr/local/directadmin/conf
    cp -f "$LOCAL_LICENSE_PATH" /usr/local/directadmin/conf/license.key
    chmod 600 /usr/local/directadmin/conf/license.key
    chown diradmin:diradmin /usr/local/directadmin/conf/license.key || true
  else
    echo "WARNING: LOCAL_LICENSE_PATH set but file not found: $LOCAL_LICENSE_PATH"
  fi
fi

# 8) Download installer to /tmp with safe filename, verify basic headers
TMP_INSTALLER="/tmp/da_installer_$(date +%s).sh"
echo "[*] Downloading installer to $TMP_INSTALLER"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --retry 3 --max-time 120 "$CUSTOM_INSTALLER_URL" -o "$TMP_INSTALLER" || bail "Không thể tải installer từ URL"
else
  wget -qO "$TMP_INSTALLER" "$CUSTOM_INSTALLER_URL" || bail "Không thể tải installer (wget)"
fi
chmod +x "$TMP_INSTALLER"
echo "[*] Installer downloaded."

# Show first lines and ask confirmation
echo "---- installer preview (first 40 lines) ----"
head -n 40 "$TMP_INSTALLER" || true
if ! confirm "Bạn có xác nhận chạy installer này? (hãy kiểm tra preview, đảm bảo là script chính thức từ vendor)"; then
  bail "Người dùng không xác nhận chạy installer."
fi

# 9) Run installer (interactive)
echo "[*] Running installer: $TMP_INSTALLER"
# Run in user's environment; user may be prompted for license/details by installer
/bin/bash "$TMP_INSTALLER" || echo "Warning: installer exited non-zero - check logs"

# 10) After install - ensure /usr/local/directadmin exists and set ethernet_dev
if [ -f /usr/local/directadmin/conf/directadmin.conf ]; then
  echo "[*] Update directadmin.conf ethernet_dev -> $IFACE"
  /usr/bin/perl -pi -e "s/^ethernet_dev=.*/ethernet_dev=${IFACE}/" /usr/local/directadmin/conf/directadmin.conf || true
  grep -q '^ethernet_dev=' /usr/local/directadmin/conf/directadmin.conf || echo "ethernet_dev=${IFACE}" >> /usr/local/directadmin/conf/directadmin.conf
fi

# 11) Restart DirectAdmin
echo "[*] Restart DirectAdmin service"
if systemctl list-unit-files | grep -q directadmin; then
  systemctl restart directadmin || true
  systemctl status directadmin --no-pager -l || true
else
  echo "Note: directadmin service not found - installer may have used other service names; check /usr/local/directadmin"
fi

# 12) Show quick checks
echo "=== Quick checks ==="
ip -br addr show "$IFACE" || true
if [ -n "$CONN" ]; then
  nmcli connection show "$CONN" | egrep "ipv4.addresses|ipv4.gateway|ipv4.method" || true
fi
echo "Show license file (if present):"
if [ -f /usr/local/directadmin/conf/license.key ]; then
  ls -l /usr/local/directadmin/conf/license.key
  echo "sha256sum:"
  sha256sum /usr/local/directadmin/conf/license.key || true
else
  echo "No license.key found."
fi

echo "[*] DONE. Kiểm tra logs: tail -n 200 /var/log/directadmin/* (nếu có) và /usr/local/directadmin/logs nếu installer dùng đó."
echo "Rollback hints:"
echo "  # remove persistent alias: nmcli connection modify \"$CONN\" -ipv4.addresses \"${ALIAS_IP}/${ALIAS_PREFIX}\""
echo "  ip addr del ${ALIAS_IP}/${ALIAS_PREFIX} dev ${IFACE}"
