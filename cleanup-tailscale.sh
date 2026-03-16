#!/usr/bin/env bash

# ============================================================
#  remove-tailscale-lxc.sh
#  Gỡ Tailscale khỏi Proxmox host + phục hồi DNS
#  cho toàn bộ LXC (Alpine/Debian/Ubuntu) và VM (guest-agent)
#  Author: based on tteck/ProxmoxVE community style
#  License: MIT
# ============================================================

set -Eeuo pipefail
trap 'echo -e "\n${RED}[ERROR]${NC} tại dòng $LINENO — exit code $?" >&2' ERR

# ════════════════════════════════════════════════════════════
#  ► CẤU HÌNH — Chỉnh sửa phần này cho phù hợp hệ thống
# ════════════════════════════════════════════════════════════

# DNS phục hồi cho Host + LXC Debian/Ubuntu
DNS_PRIMARY="10.8.6.1"        # VD: IP gateway pfSense/router nội bộ
DNS_SECONDARY="1.1.1.1"          # DNS dự phòng
DNS_TERTIARY="8.8.8.8"           # DNS dự phòng thứ 3
SEARCH_DOMAIN="localdomain"      # Search domain

# DNS phục hồi riêng cho VM (nếu khác LXC)
VM_DNS_PRIMARY="${DNS_PRIMARY}"
VM_DNS_SECONDARY="${DNS_SECONDARY}"
VM_SEARCH_DOMAIN="${SEARCH_DOMAIN}"

# Chế độ chạy: "interactive" (dùng whiptail) | "batch" (xử lý tất cả tự động)
RUN_MODE="interactive"

# Tailscale CGNAT range cần dọn khỏi iptables
TAILSCALE_CGNAT="100.64.0.0/10"
TAILSCALE_MAGIC_DNS="100.100.100.100"

# ════════════════════════════════════════════════════════════
#  Màu sắc & helper functions (theo phong cách tteck)
# ════════════════════════════════════════════════════════════
RED='\e[1;31m'; GREEN='\e[1;32m'; YELLOW='\e[1;33m'
CYAN='\e[1;36m'; BOLD='\e[1m'; NC='\e[0m'

function header_info() {
  clear
  cat <<"BANNER"
  ______      _ __                __
 /_  __/___ _(_) /_____________ _/ /__
  / / / __ `/ / / ___/ ___/ __ `/ / _ \
 / / / /_/ / / (__  ) /__/ /_/ / /  __/
/_/  \__,_/_/_/____/\___/\__,_/_/\___/
         ── REMOVER & DNS RESTORE ──

BANNER
}

function msg_info()  { echo -e " ${CYAN}➤${NC} $1"; }
function msg_ok()    { echo -e " ${GREEN}✔${NC} $1"; }
function msg_warn()  { echo -e " ${YELLOW}⚠${NC} $1"; }
function msg_error() { echo -e " ${RED}✖${NC} $1"; }
function section()   {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ════════════════════════════════════════════════════════════
#  Guard: phải chạy trên Proxmox host
# ════════════════════════════════════════════════════════════
function check_proxmox() {
  if ! command -v pveversion &>/dev/null; then
    msg_error "Script phải chạy trên Proxmox VE host, không phải bên trong container!"
    exit 232
  fi
  if [[ $EUID -ne 0 ]]; then
    msg_error "Yêu cầu quyền root!"
    exit 1
  fi
}

# ════════════════════════════════════════════════════════════
#  Tạo nội dung resolv.conf chuẩn
# ════════════════════════════════════════════════════════════
function make_resolv() {
  local pri="${1:-$DNS_PRIMARY}"
  local sec="${2:-$DNS_SECONDARY}"
  local ter="${3:-$DNS_TERTIARY}"
  local search="${4:-$SEARCH_DOMAIN}"
  cat <<EOF
nameserver ${pri}
nameserver ${sec}
nameserver ${ter}
search ${search}
EOF
}

# ════════════════════════════════════════════════════════════
#  BƯỚC 1 — Xác nhận + chọn chế độ (interactive/batch)
# ════════════════════════════════════════════════════════════
function confirm_run() {
  if [[ "$RUN_MODE" == "interactive" ]]; then
    whiptail --backtitle "Proxmox VE — Tailscale Remover" \
      --title "Xác nhận" \
      --yesno "\nScript sẽ:\n  1. Gỡ Tailscale khỏi Proxmox host\n  2. Phục hồi DNS cho tất cả LXC\n  3. Phục hồi DNS cho tất cả VM đang chạy\n\nDNS sẽ được đặt về:\n  Primary : ${DNS_PRIMARY}\n  Secondary: ${DNS_SECONDARY}\n\nTiếp tục?" \
      16 58 || exit 0
  else
    msg_warn "Chạy ở chế độ BATCH — không hỏi xác nhận"
  fi
}

# ════════════════════════════════════════════════════════════
#  BƯỚC 2 — Gỡ Tailscale khỏi Host
# ════════════════════════════════════════════════════════════
function remove_tailscale_host() {
  section "BƯỚC 1 — Gỡ Tailscale khỏi Host"

  if command -v tailscale &>/dev/null; then
    msg_info "Logout khỏi tailnet..."
    tailscale logout 2>/dev/null || msg_warn "Không thể logout (chưa login hoặc không có mạng)"

    msg_info "Dừng tailscaled service..."
    systemctl stop tailscaled 2>/dev/null || true
    systemctl disable tailscaled 2>/dev/null || true

    msg_info "Purge package tailscale..."
    DEBIAN_FRONTEND=noninteractive apt-get purge tailscale -y -qq 2>/dev/null || true
    apt-get autoremove -y -qq 2>/dev/null || true
    msg_ok "Package tailscale đã xoá"
  else
    msg_warn "Tailscale không được cài trên host, bỏ qua"
  fi

  # Dọn repository
  local removed_repo=false
  for f in /etc/apt/sources.list.d/tailscale.list \
            /usr/share/keyrings/tailscale-archive-keyring.gpg; do
    [[ -f "$f" ]] && rm -f "$f" && removed_repo=true
  done
  $removed_repo && msg_ok "Đã xoá Tailscale repository" || true

  # Dọn state/cache
  rm -rf /var/lib/tailscale /var/cache/tailscale 2>/dev/null || true
  msg_ok "Đã xoá state/cache Tailscale"

  # Xoá interface tailscale0
  if ip link show tailscale0 &>/dev/null 2>&1; then
    ip link delete tailscale0 2>/dev/null || true
    msg_ok "Đã xoá interface tailscale0"
  fi

  # Dọn iptables rules liên quan Tailscale / CGNAT
  msg_info "Dọn iptables rules Tailscale..."
  iptables-save 2>/dev/null \
    | grep -v -E "tailscale|TAILSCALE|100\.64\." \
    | iptables-restore 2>/dev/null || true
  iptables-save -t nat 2>/dev/null \
    | grep -v -E "tailscale|TAILSCALE|100\.64\." \
    | iptables-restore 2>/dev/null || true
  msg_ok "iptables đã sạch"

  # Update apt sau khi xoá repo
  apt-get update -qq 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════
#  BƯỚC 3 — Phục hồi DNS trên Host
# ════════════════════════════════════════════════════════════
function fix_host_dns() {
  section "BƯỚC 2 — Phục hồi DNS trên Host"

  if grep -q "${TAILSCALE_MAGIC_DNS}" /etc/resolv.conf 2>/dev/null; then
    msg_warn "Phát hiện MagicDNS (${TAILSCALE_MAGIC_DNS}) trên host — đang khôi phục..."
    make_resolv > /etc/resolv.conf
    msg_ok "Đã phục hồi /etc/resolv.conf trên host"
  else
    msg_ok "DNS host không bị ảnh hưởng, giữ nguyên"
  fi

  echo ""
  echo -e "  ${BOLD}DNS Host hiện tại:${NC}"
  cat /etc/resolv.conf | sed 's/^/    /'
}

# ════════════════════════════════════════════════════════════
#  BƯỚC 4 — Phục hồi DNS cho LXC (Alpine + Debian/Ubuntu)
# ════════════════════════════════════════════════════════════
function fix_single_lxc_dns() {
  local ctid="$1"
  local rootfs="/var/lib/lxc/${ctid}/rootfs"
  local resolv="${rootfs}/etc/resolv.conf"
  local is_alpine=false

  # Detect Alpine
  [[ -f "${rootfs}/etc/alpine-release" ]] && is_alpine=true

  if [[ ! -d "$rootfs" ]]; then
    msg_warn "LXC ${ctid} — Không tìm thấy rootfs tại ${rootfs}, bỏ qua"
    return
  fi

  if [[ ! -f "$resolv" ]]; then
    make_resolv > "$resolv"
    msg_ok "LXC ${ctid} — Tạo mới resolv.conf (${is_alpine} && echo 'Alpine' || echo 'Debian/Ubuntu'})"
    return
  fi

  if grep -q "${TAILSCALE_MAGIC_DNS}" "$resolv" 2>/dev/null; then
    make_resolv > "$resolv"
    if $is_alpine; then
      msg_ok "LXC ${ctid} [Alpine]   — Đã phục hồi DNS"
    else
      msg_ok "LXC ${ctid} [Debian]   — Đã phục hồi DNS"
    fi
  else
    if $is_alpine; then
      msg_ok "LXC ${ctid} [Alpine]   — DNS bình thường, giữ nguyên"
    else
      msg_ok "LXC ${ctid} [Debian]   — DNS bình thường, giữ nguyên"
    fi
  fi

  # Xoá tag 'tailscale' nếu có
  local conf="/etc/pve/lxc/${ctid}.conf"
  if [[ -f "$conf" ]] && grep -q "tailscale" "$conf"; then
    sed -i 's/; tailscale//g; s/tailscale; //g; s/tailscale//g' "$conf" 2>/dev/null || true
    # Dọn dòng tags rỗng
    sed -i '/^tags:[[:space:]]*$/d' "$conf" 2>/dev/null || true
    msg_info "LXC ${ctid} — Đã xoá tag 'tailscale'"
  fi

  # Xoá lxc.cgroup2 và lxc.mount.entry của Tailscale nếu có
  if grep -q "lxc.cgroup2.devices.allow: c 10:200 rwm" "$conf" 2>/dev/null; then
    sed -i '/lxc\.cgroup2\.devices\.allow: c 10:200 rwm/d' "$conf"
    sed -i '/lxc\.mount\.entry: \/dev\/net\/tun/d' "$conf"
    msg_info "LXC ${ctid} — Đã xoá config /dev/net/tun"
  fi
}

function fix_all_lxc_dns() {
  section "BƯỚC 3 — Phục hồi DNS cho LXC Containers"

  local lxc_list
  lxc_list=$(pct list 2>/dev/null | awk 'NR>1 {print $1}') || true

  if [[ -z "$lxc_list" ]]; then
    msg_warn "Không có LXC container nào trên host này"
    return
  fi

  # Interactive mode: cho chọn từng container cần fix
  if [[ "$RUN_MODE" == "interactive" ]]; then
    local MENU=()
    local MSG_MAX=0
    while read -r line; do
      local TAG ITEM
      TAG=$(echo "$line" | awk '{print $1}')
      ITEM=$(echo "$line" | awk '{print substr($0,36)}')
      (( ${#ITEM} + 2 > MSG_MAX )) && MSG_MAX=$(( ${#ITEM} + 2 ))
      MENU+=("$TAG" "$ITEM" "ON")
    done < <(pct list | awk 'NR>1')

    local SELECTED
    SELECTED=$(whiptail --backtitle "Proxmox VE — Tailscale Remover" \
      --title "Chọn LXC cần phục hồi DNS" \
      --checklist "\nBỏ chọn các container KHÔNG muốn sửa DNS:\n" \
      20 $((MSG_MAX + 26)) 10 \
      "${MENU[@]}" 3>&1 1>&2 2>&3) || return 0

    # Xử lý output whiptail (bỏ dấu ngoặc kép)
    lxc_list=$(echo "$SELECTED" | tr -d '"')
  fi

  for ctid in $lxc_list; do
    fix_single_lxc_dns "$ctid"
  done
}

# ════════════════════════════════════════════════════════════
#  BƯỚC 5 — Phục hồi DNS cho VM qua qemu-guest-agent
# ════════════════════════════════════════════════════════════
function fix_single_vm_dns() {
  local vmid="$1"
  local vmname
  vmname=$(qm config "$vmid" 2>/dev/null | awk -F': ' '/^name:/ {print $2}') || vmname="VM-${vmid}"

  # Kiểm tra guest-agent
  if ! qm agent "$vmid" ping &>/dev/null 2>&1; then
    msg_warn "VM ${vmid} [${vmname}] — Không có qemu-guest-agent, bỏ qua (sửa thủ công)"
    return
  fi

  # Detect OS (Linux hay Windows)
  local os_type
  os_type=$(qm config "$vmid" | awk -F': ' '/^ostype:/ {print $2}') || os_type="unknown"

  if [[ "$os_type" == win* ]]; then
    msg_warn "VM ${vmid} [${vmname}] — Windows VM, không hỗ trợ tự động, bỏ qua"
    return
  fi

  # Kiểm tra DNS hiện tại trong VM
  local current_dns=""
  current_dns=$(qm agent "$vmid" exec -- \
    bash -c "cat /etc/resolv.conf 2>/dev/null" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('out-data',''))" \
    2>/dev/null) || current_dns=""

  if echo "$current_dns" | grep -q "${TAILSCALE_MAGIC_DNS}"; then
    # Ghi resolv.conf mới vào VM
    local new_resolv
    new_resolv=$(make_resolv "$VM_DNS_PRIMARY" "$VM_DNS_SECONDARY" "$DNS_TERTIARY" "$VM_SEARCH_DOMAIN")
    qm agent "$vmid" exec -- \
      bash -c "cat > /etc/resolv.conf << 'RESOLVEOF'
${new_resolv}
RESOLVEOF" 2>/dev/null || true
    msg_ok "VM ${vmid} [${vmname}] — Đã phục hồi DNS"
  else
    msg_ok "VM ${vmid} [${vmname}] — DNS bình thường, giữ nguyên"
  fi
}

function fix_all_vm_dns() {
  section "BƯỚC 4 — Phục hồi DNS cho VMs"

  local vm_list
  vm_list=$(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}') || true

  if [[ -z "$vm_list" ]]; then
    msg_warn "Không có VM nào đang chạy"
    return
  fi

  if [[ "$RUN_MODE" == "interactive" ]]; then
    local MENU=()
    local MSG_MAX=0
    while read -r line; do
      local TAG ITEM
      TAG=$(echo "$line" | awk '{print $1}')
      ITEM=$(echo "$line" | awk '{print substr($0,10)}')
      (( ${#ITEM} + 2 > MSG_MAX )) && MSG_MAX=$(( ${#ITEM} + 2 ))
      MENU+=("$TAG" "$ITEM" "ON")
    done < <(qm list | awk 'NR>1 && $3=="running"')

    local SELECTED
    SELECTED=$(whiptail --backtitle "Proxmox VE — Tailscale Remover" \
      --title "Chọn VM cần phục hồi DNS" \
      --checklist "\nBỏ chọn các VM KHÔNG muốn sửa DNS:\n" \
      20 $((MSG_MAX + 26)) 10 \
      "${MENU[@]}" 3>&1 1>&2 2>&3) || return 0

    vm_list=$(echo "$SELECTED" | tr -d '"')
  fi

  for vmid in $vm_list; do
    fix_single_vm_dns "$vmid"
  done

  echo ""
  msg_warn "VM Windows hoặc không có qemu-guest-agent cần sửa DNS thủ công"
}

# ════════════════════════════════════════════════════════════
#  BƯỚC 6 — Kiểm tra tổng thể
# ════════════════════════════════════════════════════════════
function verify_cleanup() {
  section "BƯỚC 5 — Xác minh Kết quả"

  local all_ok=true

  command -v tailscale &>/dev/null \
    && { msg_error "Tailscale vẫn còn trên host!"; all_ok=false; } \
    || msg_ok "Tailscale đã gỡ hoàn toàn khỏi host"

  systemctl is-active tailscaled &>/dev/null \
    && { msg_error "tailscaled service vẫn đang chạy!"; all_ok=false; } \
    || msg_ok "tailscaled service đã dừng"

  ip link show tailscale0 &>/dev/null \
    && { msg_error "Interface tailscale0 vẫn còn!"; all_ok=false; } \
    || msg_ok "Interface tailscale0 đã xoá"

  grep -q "${TAILSCALE_MAGIC_DNS}" /etc/resolv.conf 2>/dev/null \
    && { msg_error "Host vẫn còn MagicDNS!"; all_ok=false; } \
    || msg_ok "DNS host sạch (không còn ${TAILSCALE_MAGIC_DNS})"

  echo ""
  if $all_ok; then
    echo -e " ${GREEN}${BOLD}✔ Hoàn tất! Mọi thứ đã sạch.${NC}"
  else
    echo -e " ${YELLOW}${BOLD}⚠ Hoàn tất với một số cảnh báo, kiểm tra lại các mục đỏ phía trên.${NC}"
  fi

  echo ""
  msg_warn "Vào Tailscale Admin Console để xoá thiết bị này ra khỏi tailnet:"
  echo -e "  ${CYAN}https://login.tailscale.com/admin/machines${NC}"
}

# ════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════
function main() {
  header_info
  check_proxmox
  confirm_run
  remove_tailscale_host
  fix_host_dns
  fix_all_lxc_dns
  fix_all_vm_dns
  verify_cleanup
}

# ── Cho phép chạy batch qua argument ────────────────────────
# VD: ./remove-tailscale-lxc.sh --batch --dns 10.0.0.1 --dns2 1.1.1.1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --batch)   RUN_MODE="batch"; shift ;;
    --dns)     DNS_PRIMARY="$2"; VM_DNS_PRIMARY="$2"; shift 2 ;;
    --dns2)    DNS_SECONDARY="$2"; VM_DNS_SECONDARY="$2"; shift 2 ;;
    --search)  SEARCH_DOMAIN="$2"; VM_SEARCH_DOMAIN="$2"; shift 2 ;;
    --help)
      echo "Usage: $0 [--batch] [--dns IP] [--dns2 IP] [--search DOMAIN]"
      echo "  --batch       Không hỏi xác nhận, xử lý tất cả tự động"
      echo "  --dns IP      DNS primary (default: ${DNS_PRIMARY})"
      echo "  --dns2 IP     DNS secondary (default: ${DNS_SECONDARY})"
      echo "  --search STR  Search domain (default: ${SEARCH_DOMAIN})"
      exit 0 ;;
    *) msg_error "Tham số không hợp lệ: $1"; exit 1 ;;
  esac
done

main
