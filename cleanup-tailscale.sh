#!/bin/bash
# ============================================================
#  cleanup-tailscale.sh
#  Gỡ Tailscale hoàn toàn khỏi Proxmox host và
#  phục hồi DNS cho toàn bộ LXC container + VM (qemu-agent)
# ============================================================

set -euo pipefail

# ── CẤU HÌNH DNS (sửa cho phù hợp hệ thống của bạn) ────────
DNS_PRIMARY="192.168.1.1"      # Gateway pfSense hoặc DNS server nội bộ
DNS_SECONDARY="1.1.1.1"        # DNS dự phòng
SEARCH_DOMAIN="localdomain"
# ────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✘]${NC} $1"; }

check_root() {
    [[ $EUID -ne 0 ]] && err "Script phải chạy với quyền root!" && exit 1
}

# ── Nội dung resolv.conf chuẩn ──────────────────────────────
make_resolv_conf() {
    cat <<EOF
nameserver ${DNS_PRIMARY}
nameserver ${DNS_SECONDARY}
search ${SEARCH_DOMAIN}
EOF
}

# ── BƯỚC 1: Logout và dừng Tailscale ────────────────────────
remove_tailscale() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " BƯỚC 1 — Gỡ Tailscale khỏi Host"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if command -v tailscale &>/dev/null; then
        log "Logout khỏi tailnet..."
        tailscale logout 2>/dev/null || warn "Không thể logout (có thể chưa login)"

        log "Dừng và disable tailscaled service..."
        systemctl stop tailscaled 2>/dev/null || true
        systemctl disable tailscaled 2>/dev/null || true

        log "Purge package tailscale..."
        apt-get purge tailscale -y -qq
        apt-get autoremove -y -qq
    else
        warn "Tailscale không được cài trên host, bỏ qua bước gỡ package"
    fi

    log "Xoá Tailscale repository..."
    rm -f /etc/apt/sources.list.d/tailscale.list
    rm -f /usr/share/keyrings/tailscale-archive-keyring.gpg
    apt-get update -qq

    log "Xoá thư mục state của Tailscale..."
    rm -rf /var/lib/tailscale
    rm -rf /var/cache/tailscale

    # Xoá interface tailscale0 nếu còn
    if ip link show tailscale0 &>/dev/null; then
        log "Xoá network interface tailscale0..."
        ip link delete tailscale0 2>/dev/null || true
    fi

    # Xoá iptables rules liên quan Tailscale
    log "Dọn iptables rules của Tailscale..."
    iptables-save | grep -v 'tailscale\|TAILSCALE\|100\.64\.' | iptables-restore 2>/dev/null || true
    iptables-save -t nat | grep -v 'tailscale\|TAILSCALE\|100\.64\.' | iptables-restore -t nat 2>/dev/null || true

    log "Tailscale đã được gỡ khỏi host."
}

# ── BƯỚC 2: Phục hồi DNS trên Host ──────────────────────────
fix_host_dns() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " BƯỚC 2 — Phục hồi DNS trên Host"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if grep -q "100\.100\.100\.100" /etc/resolv.conf 2>/dev/null; then
        warn "Phát hiện DNS Tailscale (100.100.100.100) trên host, đang khôi phục..."
        make_resolv_conf > /etc/resolv.conf
        log "Đã phục hồi /etc/resolv.conf trên host"
    else
        log "DNS host không bị ảnh hưởng bởi Tailscale, giữ nguyên"
    fi

    log "DNS host hiện tại:"
    cat /etc/resolv.conf | sed 's/^/    /'
}

# ── BƯỚC 3: Fix DNS cho tất cả LXC container ────────────────
fix_lxc_dns() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " BƯỚC 3 — Phục hồi DNS cho LXC"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local lxc_list
    lxc_list=$(pct list 2>/dev/null | awk 'NR>1 {print $1}') || true

    if [[ -z "$lxc_list" ]]; then
        warn "Không tìm thấy LXC container nào"
        return
    fi

    for ctid in $lxc_list; do
        local rootfs="/var/lib/lxc/${ctid}/rootfs"
        local resolv="${rootfs}/etc/resolv.conf"

        echo -n "  LXC ${ctid}: "

        if [[ ! -d "$rootfs" ]]; then
            warn "Không tìm thấy rootfs tại ${rootfs}, bỏ qua"
            continue
        fi

        if [[ ! -f "$resolv" ]]; then
            warn "LXC ${ctid} chưa có resolv.conf, tạo mới..."
            make_resolv_conf > "$resolv"
            log "LXC ${ctid} — Đã tạo resolv.conf mới"
            continue
        fi

        if grep -q "100\.100\.100\.100" "$resolv" 2>/dev/null; then
            make_resolv_conf > "$resolv"
            log "LXC ${ctid} — Đã phục hồi DNS (có dấu vết Tailscale MagicDNS)"
        else
            log "LXC ${ctid} — DNS bình thường, không cần sửa"
        fi
    done
}

# ── BƯỚC 4: Fix DNS cho VM qua qemu-guest-agent ─────────────
fix_vm_dns() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " BƯỚC 4 — Phục hồi DNS cho VM"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local vm_list
    vm_list=$(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}') || true

    if [[ -z "$vm_list" ]]; then
        warn "Không có VM nào đang chạy"
        return
    fi

    local resolv_content
    resolv_content=$(make_resolv_conf)

    for vmid in $vm_list; do
        echo -n "  VM ${vmid}: "

        # Kiểm tra qemu-guest-agent có hoạt động không
        if ! qm agent "${vmid}" ping &>/dev/null 2>&1; then
            warn "VM ${vmid} — Không có qemu-guest-agent, bỏ qua (sửa thủ công)"
            continue
        fi

        # Kiểm tra DNS trong VM
        local current_dns
        current_dns=$(qm agent "${vmid}" exec -- bash -c \
            "cat /etc/resolv.conf 2>/dev/null || echo ''" 2>/dev/null \
            | grep -o '"out-data":"[^"]*"' | sed 's/"out-data":"//;s/"$//' || echo "")

        if echo "$current_dns" | grep -q "100\.100\.100\.100"; then
            qm agent "${vmid}" exec -- bash -c \
                "echo '${resolv_content}' > /etc/resolv.conf" 2>/dev/null || true
            log "VM ${vmid} — Đã phục hồi DNS"
        else
            log "VM ${vmid} — DNS bình thường, không cần sửa"
        fi
    done

    warn "Các VM không có qemu-guest-agent cần kiểm tra DNS thủ công"
}

# ── BƯỚC 5: Kiểm tra kết quả ────────────────────────────────
verify() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " BƯỚC 5 — Xác minh kết quả"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    command -v tailscale &>/dev/null \
        && err  "Tailscale vẫn còn tồn tại!" \
        || log  "Tailscale đã bị gỡ hoàn toàn"

    systemctl is-active tailscaled &>/dev/null \
        && err  "tailscaled service vẫn đang chạy!" \
        || log  "tailscaled service đã dừng"

    ip link show tailscale0 &>/dev/null \
        && err  "Interface tailscale0 vẫn còn!" \
        || log  "Interface tailscale0 đã xoá"

    grep -q "100\.100\.100\.100" /etc/resolv.conf 2>/dev/null \
        && err  "Host vẫn còn DNS Tailscale!" \
        || log  "DNS host sạch"

    echo ""
    log "Hoàn tất! Kiểm tra Tailscale Admin để xoá thiết bị này khỏi tailnet."
}

# ── MAIN ────────────────────────────────────────────────────
main() {
    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║   Tailscale Cleanup — Proxmox Host   ║"
    echo "╚══════════════════════════════════════╝"

    check_root
    remove_tailscale
    fix_host_dns
    fix_lxc_dns
    fix_vm_dns
    verify
}

main "$@"
