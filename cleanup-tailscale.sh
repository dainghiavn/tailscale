#!/usr/bin/env bash

# ============================================================
#  remove-tailscale-lxc.sh
#  Gỡ Tailscale khỏi Proxmox host + phục hồi DNS
#  cho toàn bộ LXC (Alpine/Debian/Ubuntu) và VM (guest-agent)
#  Author: based on tteck/ProxmoxVE community style
#  License: MIT
# ============================================================

set -Eeuo pipefail
trap 'msg_error "Lỗi không mong muốn tại dòng $LINENO — exit code $?. Script dừng lại."; exit 1' ERR

# ════════════════════════════════════════════════════════════
#  ► CẤU HÌNH MẶC ĐỊNH
# ════════════════════════════════════════════════════════════
DNS_PRIMARY="10.8.6.1"
DNS_SECONDARY="1.1.1.1"
DNS_TERTIARY="8.8.8.8"
SEARCH_DOMAIN="localdomain"
VM_DNS_PRIMARY="${DNS_PRIMARY}"
VM_DNS_SECONDARY="${DNS_SECONDARY}"
VM_SEARCH_DOMAIN="${SEARCH_DOMAIN}"
RUN_MODE="interactive"
TAILSCALE_MAGIC_DNS="100.100.100.100"

# ════════════════════════════════════════════════════════════
#  Màu sắc & helper functions
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

function msg_info()  { echo -e " ${CYAN}➤${NC}  $1"; }
function msg_ok()    { echo -e " ${GREEN}✔${NC}  $1"; }
function msg_warn()  { echo -e " ${YELLOW}⚠${NC}  $1"; }
function msg_error() { echo -e " ${RED}✖${NC}  $1"; }
function msg_skip()  { echo -e " ${YELLOW}↷${NC}  $1 ${YELLOW}(bỏ qua)${NC}"; }
function section() {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ════════════════════════════════════════════════════════════
#  Guard: phải chạy trên Proxmox host với quyền root
# ════════════════════════════════════════════════════════════
function check_proxmox() {
  if ! command -v pveversion &>/dev/null; then
    msg_error "Script phải chạy trên Proxmox VE host, không phải bên trong container!"
    exit 232
  fi
  if [[ $EUID -ne 0 ]]; then
    msg_error "Yêu cầu quyền root! Hãy chạy bằng sudo hoặc root."
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
#  PRE-FLIGHT: Rà soát toàn bộ hệ thống trước khi thực thi
# ════════════════════════════════════════════════════════════
function preflight_check() {
  section "PRE-FLIGHT — Rà soát hệ thống"

  local ts_found=false
  local warnings=0

  # 1) Kiểm tra Tailscale binary trên host
  if command -v tailscale &>/dev/null; then
    msg_ok  "Tìm thấy Tailscale binary: $(command -v tailscale)"
    ts_found=true
  else
    msg_skip "Không tìm thấy Tailscale binary trên host"
  fi

  # 2) Kiểm tra tailscaled service
  if systemctl list-units --all --no-legend 2>/dev/null | grep -q "tailscaled"; then
    msg_ok "Tìm thấy tailscaled systemd service"
    ts_found=true
  else
    msg_skip "Không tìm thấy tailscaled systemd service"
  fi

  # 3) Kiểm tra interface tailscale0
  if ip link show tailscale0 &>/dev/null 2>&1; then
    msg_ok "Tìm thấy network interface tailscale0"
    ts_found=true
  else
    msg_skip "Không tìm thấy interface tailscale0"
  fi

  # 4) Kiểm tra Tailscale repository
  if [[ -f /etc/apt/sources.list.d/tailscale.list ]]; then
    msg_ok "Tìm thấy Tailscale apt repository"
    ts_found=true
  else
    msg_skip "Không tìm thấy Tailscale apt repository"
  fi

  # 5) Kiểm tra MagicDNS trên host
  if grep -q "${TAILSCALE_MAGIC_DNS}" /etc/resolv.conf 2>/dev/null; then
    msg_warn "Host đang dùng Tailscale MagicDNS (${TAILSCALE_MAGIC_DNS}) → sẽ phục hồi"
    ts_found=true
    (( warnings++ )) || true
  else
    msg_ok "Host không dùng MagicDNS"
  fi

  # 6) Kiểm tra state directory
  if [[ -d /var/lib/tailscale ]]; then
    msg_ok "Tìm thấy Tailscale state directory (/var/lib/tailscale)"
    ts_found=true
  else
    msg_skip "Không tìm thấy Tailscale state directory"
  fi

  # 7) Kiểm tra iptables rules Tailscale
  if iptables-save 2>/dev/null | grep -qiE "tailscale|100\.64\."; then
    msg_warn "Tìm thấy iptables rules liên quan Tailscale → sẽ dọn"
    (( warnings++ )) || true
  else
    msg_ok "Không có iptables rules của Tailscale"
  fi

  # 8) Kiểm tra LXC containers
  local lxc_count
  lxc_count=$(pct list 2>/dev/null | awk 'NR>1' | wc -l) || lxc_count=0
  if [[ "$lxc_count" -gt 0 ]]; then
    msg_ok "Tìm thấy ${lxc_count} LXC container(s) → sẽ kiểm tra DNS"
  else
    msg_skip "Không có LXC container nào trên host"
  fi

  # 9) Kiểm tra VM đang chạy
  local vm_count
  vm_count=$(qm list 2>/dev/null | awk 'NR>1 && $3=="running"' | wc -l) || vm_count=0
  if [[ "$vm_count" -gt 0 ]]; then
    msg_ok "Tìm thấy ${vm_count} VM đang chạy → sẽ kiểm tra DNS (cần guest-agent)"
  else
    msg_skip "Không có VM nào đang chạy"
  fi

  echo ""

  # ── QUYẾT ĐỊNH: Có Tailscale không? ────────────────────
  if ! $ts_found; then
    echo -e " ${YELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${YELLOW}${BOLD}  KHÔNG TÌM THẤY TAILSCALE TRÊN HỆ THỐNG${NC}"
    echo -e " ${YELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    msg_info "Tailscale chưa được cài trên Proxmox host này."
    msg_info "Không cần thực hiện thêm thao tác nào."
    echo ""
    exit 0
  fi

  if [[ "$warnings" -gt 0 ]]; then
    msg_warn "Phát hiện ${warnings} mục cần xử lý — tiếp tục script..."
  else
    msg_info "Rà soát hoàn tất — bắt đầu dọn dẹp..."
  fi
}

# ════════════════════════════════════════════════════════════
#  Xác nhận trước khi thực thi
# ════════════════════════════════════════════════════════════
function confirm_run() {
  if [[ "$RUN_MODE" == "interactive" ]]; then
    whiptail --backtitle "Proxmox VE — Tailscale Remover" \
      --title "Xác nhận thực thi" \
      --yesno "\nScript sẽ thực hiện:\n\n  1. Gỡ Tailscale khỏi Proxmox host\n  2. Dọn iptables rules Tailscale\n  3. Phục hồi DNS cho tất cả LXC\n  4. Phục hồi DNS cho VM đang chạy\n\nDNS sẽ đặt về:\n  Primary  : ${DNS_PRIMARY}\n  Secondary: ${DNS_SECONDARY}\n  Tertiary : ${DNS_TERTIARY}\n\nTiếp tục?" \
      20 58 || { msg_warn "Người dùng huỷ. Thoát."; exit 0; }
  else
    msg_warn "Chạy ở chế độ BATCH — không hỏi xác nhận"
  fi
}

# ════════════════════════════════════════════════════════════
#  BƯỚC 1 — Gỡ Tailscale khỏi Host
# ════════════════════════════════════════════════════════════
function remove_tailscale_host() {
  section "BƯỚC 1 — Gỡ Tailscale khỏi Host"

  # Logout
  if command -v tailscale &>/dev/null; then
    msg_info "Logout khỏi tailnet..."
    tailscale logout 2>/dev/null \
      && msg_ok "Đã logout khỏi tailnet" \
      || msg_warn "Không thể logout (mất mạng hoặc chưa login) — bỏ qua"

    msg_info "Dừng tailscaled service..."
    systemctl stop tailscaled 2>/dev/null    || true
    systemctl disable tailscaled 2>/dev/null || true
    msg_ok "tailscaled đã dừng và disabled"

    msg_info "Purge package tailscale..."
    DEBIAN_FRONTEND=noninteractive apt-get purge tailscale -y -qq 2>/dev/null \
      && msg_ok "Package tailscale đã xoá" \
      || msg_warn "Purge package thất bại — có thể đã bị xoá trước đó"
    apt-get autoremove -y -qq 2>/dev/null || true
  else
    msg_skip "Không tìm thấy tailscale binary — bỏ bước purge"
  fi

  # Dọn repository
  local removed_repo=false
  for f in /etc/apt/sources.list.d/tailscale.list \
            /usr/share/keyrings/tailscale-archive-keyring.gpg; do
    if [[ -f "$f" ]]; then
      rm -f "$f" && removed_repo=true
    fi
  done
  $removed_repo \
    && msg_ok "Đã xoá Tailscale apt repository" \
    || msg_skip "Không tìm thấy repository Tailscale — bỏ qua"

  # Dọn state/cache
  if [[ -d /var/lib/tailscale ]] || [[ -d /var/cache/tailscale ]]; then
    rm -rf /var/lib/tailscale /var/cache/tailscale 2>/dev/null || true
    msg_ok "Đã xoá state/cache Tailscale"
  else
    msg_skip "Không tìm thấy state/cache Tailscale — bỏ qua"
  fi

  # Xoá interface tailscale0
  if ip link show tailscale0 &>/dev/null 2>&1; then
    ip link delete tailscale0 2>/dev/null \
      && msg_ok "Đã xoá interface tailscale0" \
      || msg_warn "Không xoá được tailscale0 — có thể cần reboot"
  else
    msg_skip "Không tìm thấy interface tailscale0 — bỏ qua"
  fi

  # Dọn iptables
  if iptables-save 2>/dev/null | grep -qiE "tailscale|100\.64\."; then
    msg_info "Dọn iptables rules Tailscale..."
    iptables-save 2>/dev/null \
      | grep -v -iE "tailscale|100\.64\." \
      | iptables-restore 2>/dev/null || true
    iptables-save -t nat 2>/dev/null \
      | grep -v -iE "tailscale|100\.64\." \
      | iptables-restore 2>/dev/null || true
    msg_ok "iptables đã sạch"
  else
    msg_skip "Không có iptables rules Tailscale — bỏ qua"
  fi

  # Update apt
  msg_info "Cập nhật apt cache..."
  apt-get update -qq 2>/dev/null \
    && msg_ok "apt cache đã cập nhật" \
    || msg_warn "apt update thất bại — không ảnh hưởng đến quá trình gỡ"
}

# ════════════════════════════════════════════════════════════
#  BƯỚC 2 — Phục hồi DNS trên Host
# ════════════════════════════════════════════════════════════
function fix_host_dns() {
  section "BƯỚC 2 — Phục hồi DNS trên Host"

  if [[ ! -f /etc/resolv.conf ]]; then
    msg_warn "/etc/resolv.conf không tồn tại — tạo mới..."
    make_resolv > /etc/resolv.conf
    msg_ok "Đã tạo /etc/resolv.conf mới"
    return
  fi

  if grep -q "${TAILSCALE_MAGIC_DNS}" /etc/resolv.conf 2>/dev/null; then
    msg_warn "Phát hiện MagicDNS (${TAILSCALE_MAGIC_DNS}) — đang khôi phục..."
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
#  BƯỚC 3 — Phục hồi DNS cho từng LXC
# ════════════════════════════════════════════════════════════
function fix_single_lxc_dns() {
  local ctid="$1"
  local conf="/etc/pve/lxc/${ctid}.conf"

  # Đọc trạng thái an toàn
  local status="unknown"
  status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}') || status="unknown"

  # Detect OS
  local os_label="Linux"
  local ostype=""
  ostype=$(awk -F': ' '/^ostype:/ {print $2}' "$conf" 2>/dev/null) || ostype=""
  [[ "$ostype" == *"alpine"* ]] && os_label="Alpine"

  # ── Container đang RUNNING → pct exec ───────────────────
  _fix_running() {
    local raw check
    # Lấy output và strip toàn bộ whitespace/newline
    raw=$(pct exec "$ctid" -- sh -c \
      "grep -c '${TAILSCALE_MAGIC_DNS}' /etc/resolv.conf 2>/dev/null || echo 0" \
      2>/dev/null) || raw="0"
    check=$(echo "$raw" | tr -d '[:space:]')
    # Đảm bảo là số nguyên
    [[ "$check" =~ ^[0-9]+$ ]] || check=0

    if [[ "$check" -gt 0 ]]; then
      pct exec "$ctid" -- sh -c "cat > /etc/resolv.conf << 'RESOLVEOF'
$(make_resolv)
RESOLVEOF" 2>/dev/null && \
      msg_ok "LXC ${ctid} [${os_label}] [running] — Đã phục hồi DNS" || \
      msg_warn "LXC ${ctid} — Không thể ghi resolv.conf (quyền truy cập?)"
    else
      msg_ok "LXC ${ctid} [${os_label}] [running] — DNS bình thường, giữ nguyên"
    fi
  }

  # ── Container đang STOPPED → pct mount ──────────────────
  _fix_stopped() {
    local mount_output mp

    # Chạy pct mount và bắt lỗi mềm
    mount_output=$(pct mount "$ctid" 2>/dev/null) || {
      msg_warn "LXC ${ctid} [${os_label}] [stopped] — pct mount thất bại, bỏ qua"
      return
    }

    # Parse path từ output dạng: "mounted CT 102 in '/var/lib/lxc/102/rootfs'"
    mp=$(echo "$mount_output" | grep -oP "(?<=')[^']+" | tail -1 2>/dev/null) || mp=""

    # Fallback nếu regex không match
    if [[ -z "$mp" ]]; then
      mp=$(echo "$mount_output" | awk '{print $NF}' | tr -d "'" 2>/dev/null) || mp=""
    fi

    # Kiểm tra path hợp lệ
    if [[ -z "$mp" ]] || [[ ! -d "$mp" ]]; then
      pct unmount "$ctid" 2>/dev/null || true
      msg_warn "LXC ${ctid} [${os_label}] [stopped] — Không xác định được mount path, bỏ qua"
      return
    fi

    local resolv="${mp}/etc/resolv.conf"

    if [[ ! -f "$resolv" ]]; then
      make_resolv > "$resolv" 2>/dev/null \
        && msg_ok "LXC ${ctid} [${os_label}] [stopped] — Tạo mới resolv.conf" \
        || msg_warn "LXC ${ctid} — Không thể tạo resolv.conf"
    elif grep -q "${TAILSCALE_MAGIC_DNS}" "$resolv" 2>/dev/null; then
      make_resolv > "$resolv" 2>/dev/null \
        && msg_ok "LXC ${ctid} [${os_label}] [stopped] — Đã phục hồi DNS" \
        || msg_warn "LXC ${ctid} — Không thể ghi resolv.conf"
    else
      msg_ok "LXC ${ctid} [${os_label}] [stopped] — DNS bình thường, giữ nguyên"
    fi

    pct unmount "$ctid" 2>/dev/null || true
  }

  # ── Dispatch theo trạng thái ─────────────────────────────
  case "$status" in
    running) _fix_running ;;
    stopped) _fix_stopped ;;
    paused)  msg_skip "LXC ${ctid} [${os_label}] đang paused — không thể xử lý" ;;
    *)       msg_skip "LXC ${ctid} [${os_label}] trạng thái không xác định (${status})" ;;
  esac

  # ── Dọn tag tailscale + cgroup tun config ───────────────
  if [[ -f "$conf" ]]; then
    if grep -q "tailscale" "$conf" 2>/dev/null; then
      sed -i 's/; tailscale//g; s/tailscale; //g; s/\btailscale\b//g' "$conf" 2>/dev/null || true
      sed -i '/^tags:[[:space:]]*$/d' "$conf" 2>/dev/null || true
      msg_info "LXC ${ctid} — Đã xoá tag 'tailscale' khỏi config"
    fi
    if grep -q "lxc.cgroup2.devices.allow: c 10:200 rwm" "$conf" 2>/dev/null; then
      sed -i '/lxc\.cgroup2\.devices\.allow: c 10:200 rwm/d' "$conf" 2>/dev/null || true
      sed -i '/lxc\.mount\.entry: \/dev\/net\/tun/d' "$conf" 2>/dev/null || true
      msg_info "LXC ${ctid} — Đã xoá config /dev/net/tun"
    fi
  else
    msg_warn "LXC ${ctid} — Không tìm thấy file config tại ${conf}"
  fi
}

function fix_all_lxc_dns() {
  section "BƯỚC 3 — Phục hồi DNS cho LXC Containers"

  local lxc_list=""
  lxc_list=$(pct list 2>/dev/null | awk 'NR>1 {print $1}') || lxc_list=""

  if [[ -z "$lxc_list" ]]; then
    msg_skip "Không có LXC container nào — bỏ qua bước này"
    return
  fi

  if [[ "$RUN_MODE" == "interactive" ]]; then
    local MENU=() MSG_MAX=0
    while read -r line; do
      local TAG ITEM
      TAG=$(echo "$line" | awk '{print $1}')
      ITEM=$(echo "$line" | awk '{print substr($0,36)}')
      (( ${#ITEM} + 2 > MSG_MAX )) && MSG_MAX=$(( ${#ITEM} + 2 ))
      MENU+=("$TAG" "$ITEM" "ON")
    done < <(pct list | awk 'NR>1')

    local SELECTED=""
    SELECTED=$(whiptail \
      --backtitle "Proxmox VE — Tailscale Remover" \
      --title "Chọn LXC cần phục hồi DNS" \
      --checklist "\nBỏ chọn các container KHÔNG muốn sửa DNS:\n" \
      20 $((MSG_MAX + 26)) 10 \
      "${MENU[@]}" 3>&1 1>&2 2>&3) || {
        msg_warn "Không chọn container nào — bỏ qua bước LXC"
        return
      }
    lxc_list=$(echo "$SELECTED" | tr -d '"')
  fi

  if [[ -z "$lxc_list" ]]; then
    msg_skip "Không có LXC nào được chọn — bỏ qua"
    return
  fi

  for ctid in $lxc_list; do
    fix_single_lxc_dns "$ctid"
  done
}

# ════════════════════════════════════════════════════════════
#  BƯỚC 4 — Phục hồi DNS cho VM
# ════════════════════════════════════════════════════════════
function fix_single_vm_dns() {
  local vmid="$1"
  local vmname="VM-${vmid}"
  vmname=$(qm config "$vmid" 2>/dev/null | awk -F': ' '/^name:/ {print $2}') || vmname="VM-${vmid}"

  # Kiểm tra OS type
  local os_type="unknown"
  os_type=$(qm config "$vmid" 2>/dev/null | awk -F': ' '/^ostype:/ {print $2}') || os_type="unknown"

  if [[ "$os_type" == win* ]]; then
    msg_skip "VM ${vmid} [${vmname}] là Windows — không hỗ trợ tự động, sửa thủ công"
    return
  fi

  # Kiểm tra guest-agent
  if ! qm agent "$vmid" ping &>/dev/null 2>&1; then
    msg_skip "VM ${vmid} [${vmname}] — Không có qemu-guest-agent (pfSense/BSD/tắt agent)"
    return
  fi

  # Đọc DNS hiện tại
  local current_dns=""
  current_dns=$(qm agent "$vmid" exec -- \
    bash -c "cat /etc/resolv.conf 2>/dev/null || echo ''" 2>/dev/null \
    | python3 -c \
      "import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('out-data',''))
except:
    print('')" 2>/dev/null) || current_dns=""

  if echo "$current_dns" | grep -q "${TAILSCALE_MAGIC_DNS}"; then
    local new_resolv
    new_resolv=$(make_resolv "$VM_DNS_PRIMARY" "$VM_DNS_SECONDARY" "$DNS_TERTIARY" "$VM_SEARCH_DOMAIN")
    qm agent "$vmid" exec -- bash -c \
      "printf '%s\n' '${new_resolv}' > /etc/resolv.conf" 2>/dev/null \
      && msg_ok "VM ${vmid} [${vmname}] — Đã phục hồi DNS" \
      || msg_warn "VM ${vmid} [${vmname}] — Không thể ghi resolv.conf"
  else
    msg_ok "VM ${vmid} [${vmname}] — DNS bình thường, giữ nguyên"
  fi
}

function fix_all_vm_dns() {
  section "BƯỚC 4 — Phục hồi DNS cho VMs"

  local vm_list=""
  vm_list=$(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}') || vm_list=""

  if [[ -z "$vm_list" ]]; then
    msg_skip "Không có VM nào đang chạy — bỏ qua bước này"
    return
  fi

  if [[ "$RUN_MODE" == "interactive" ]]; then
    local MENU=() MSG_MAX=0
    while read -r line; do
      local TAG ITEM
      TAG=$(echo "$line" | awk '{print $1}')
      ITEM=$(echo "$line" | awk '{print substr($0,10)}')
      (( ${#ITEM} + 2 > MSG_MAX )) && MSG_MAX=$(( ${#ITEM} + 2 ))
      MENU+=("$TAG" "$ITEM" "ON")
    done < <(qm list | awk 'NR>1 && $3=="running"')

    local SELECTED=""
    SELECTED=$(whiptail \
      --backtitle "Proxmox VE — Tailscale Remover" \
      --title "Chọn VM cần phục hồi DNS" \
      --checklist "\nBỏ chọn các VM KHÔNG muốn sửa DNS:\n" \
      20 $((MSG_MAX + 26)) 10 \
      "${MENU[@]}" 3>&1 1>&2 2>&3) || {
        msg_warn "Không chọn VM nào — bỏ qua bước VM"
        return
      }
    vm_list=$(echo "$SELECTED" | tr -d '"')
  fi

  if [[ -z "$vm_list" ]]; then
    msg_skip "Không có VM nào được chọn — bỏ qua"
    return
  fi

  for vmid in $vm_list; do
    fix_single_vm_dns "$vmid"
  done

  echo ""
  msg_warn "VM Windows / không có qemu-guest-agent → kiểm tra DNS thủ công"
}

# ════════════════════════════════════════════════════════════
#  BƯỚC 5 — Xác minh kết quả
# ════════════════════════════════════════════════════════════
function verify_cleanup() {
  section "BƯỚC 5 — Xác minh Kết quả"

  local all_ok=true

  command -v tailscale &>/dev/null \
    && { msg_error "Tailscale binary vẫn còn!"; all_ok=false; } \
    || msg_ok "Tailscale binary đã xoá"

  systemctl is-active tailscaled &>/dev/null \
    && { msg_error "tailscaled service vẫn đang chạy!"; all_ok=false; } \
    || msg_ok "tailscaled service đã dừng"

  ip link show tailscale0 &>/dev/null \
    && { msg_error "Interface tailscale0 vẫn còn!"; all_ok=false; } \
    || msg_ok "Interface tailscale0 đã xoá"

  grep -q "${TAILSCALE_MAGIC_DNS}" /etc/resolv.conf 2>/dev/null \
    && { msg_error "Host vẫn còn MagicDNS (${TAILSCALE_MAGIC_DNS})!"; all_ok=false; } \
    || msg_ok "DNS host sạch"

  [[ -d /var/lib/tailscale ]] \
    && { msg_warn "State directory vẫn còn (/var/lib/tailscale)"; all_ok=false; } \
    || msg_ok "State directory đã xoá"

  echo ""
  if $all_ok; then
    echo -e " ${GREEN}${BOLD}✔  Hoàn tất! Hệ thống đã sạch Tailscale.${NC}"
  else
    echo -e " ${YELLOW}${BOLD}⚠  Hoàn tất với một số cảnh báo — xem lại mục đỏ/vàng phía trên.${NC}"
  fi

  echo ""
  msg_warn "Xoá thiết bị này khỏi Tailscale Admin Console:"
  echo -e "  ${CYAN}https://login.tailscale.com/admin/machines${NC}"
}

# ════════════════════════════════════════════════════════════
#  Parse CLI arguments
# ════════════════════════════════════════════════════════════
while [[ $# -gt 0 ]]; do
  case "$1" in
    --batch)  RUN_MODE="batch"; shift ;;
    --dns)    DNS_PRIMARY="$2";   VM_DNS_PRIMARY="$2";   shift 2 ;;
    --dns2)   DNS_SECONDARY="$2"; VM_DNS_SECONDARY="$2"; shift 2 ;;
    --dns3)   DNS_TERTIARY="$2";  shift 2 ;;
    --search) SEARCH_DOMAIN="$2"; VM_SEARCH_DOMAIN="$2"; shift 2 ;;
    --help)
      echo "Usage: $0 [--batch] [--dns IP] [--dns2 IP] [--dns3 IP] [--search DOMAIN]"
      echo ""
      echo "  --batch        Không hỏi xác nhận, xử lý tất cả tự động"
      echo "  --dns   IP     DNS primary   (default: ${DNS_PRIMARY})"
      echo "  --dns2  IP     DNS secondary (default: ${DNS_SECONDARY})"
      echo "  --dns3  IP     DNS tertiary  (default: ${DNS_TERTIARY})"
      echo "  --search STR   Search domain (default: ${SEARCH_DOMAIN})"
      echo ""
      echo "Ví dụ:"
      echo "  $0 --batch --dns 10.8.6.1 --dns2 1.1.1.1 --search home.lab"
      exit 0 ;;
    *) msg_error "Tham số không hợp lệ: '$1' — dùng --help để xem hướng dẫn"; exit 1 ;;
  esac
done

# ════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════
function main() {
  header_info
  check_proxmox
  preflight_check    # ← Rà soát, tự EXIT nếu không có Tailscale
  confirm_run
  remove_tailscale_host
  fix_host_dns
  fix_all_lxc_dns
  fix_all_vm_dns
  verify_cleanup
}

main
