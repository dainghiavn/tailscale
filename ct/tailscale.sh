#!/usr/bin/env bash
# =============================================================================
# tailscale-proxmox/ct/tailscale.sh
#
# Cài đặt Tailscale vào LXC mới trên Proxmox
# Tác giả  : dainghiavn
# License  : MIT
# Source   : https://tailscale.com
#
# Chạy lệnh này trên Proxmox shell:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/dainghiavn/tailscale/main/ct/tailscale.sh)"
# =============================================================================

# ── Import bash-lib ───────────────────────────────────────────────────────────
BASHLIB_APP_NAME="tailscale-install"
BASHLIB_LOG_DIR="/var/log/tailscale-proxmox"
source <(curl -fsSL https://raw.githubusercontent.com/dainghiavn/bash-lib/main/lib.sh) || {
    echo "[ERROR] Không load được bash-lib — kiểm tra internet" >&2
    exit 1
}
load_network
load_proxmox

# ── Thông số mặc định LXC ────────────────────────────────────────────────────
readonly APP="Tailscale"
readonly APP_VERSION="latest"
readonly INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/dainghiavn/tailscale/main/install/tailscale-install.sh"

# LXC defaults — override được bằng biến môi trường
CTID="${CTID:-}"                        # tự động tìm nếu để trống
CT_HOSTNAME="${CT_HOSTNAME:-tailscale}"
CT_RAM="${CT_RAM:-128}"                 # MB
CT_CPU="${CT_CPU:-1}"
CT_DISK="${CT_DISK:-2}"                 # GB
CT_OS="${CT_OS:-debian}"
CT_OS_VERSION="${CT_OS_VERSION:-12}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_UNPRIVILEGED="${CT_UNPRIVILEGED:-1}"

# Tailscale options — được set từ menu
TS_AUTHKEY=""
TS_INSTALL_MODE="simple"               # simple | advanced
TS_ENABLE_SUBNET=0
TS_ENABLE_EXITNODE=0
TS_ENABLE_SSH=0
TS_SUBNET_ROUTES=""
TS_HOSTNAME=""

# Preflight scoring
PREFLIGHT_SCORE=0
PREFLIGHT_VERDICT=""                   # GO | WARN | STOP | ABORT
NET_CONN_MODE="unknown"               # direct | hybrid | derp_only | no_connection

# =============================================================================
# PHASE 0 — Entry + Header
# =============================================================================
_phase0_entry() {
    catch_errors
    check_root

    header_info "$APP" "$APP_VERSION"

    echo -e "  ${C_DIM}Installer cho Proxmox LXC${CL}"
    echo -e "  ${C_DIM}Log: $(get_log_file)${CL}"
    echo ""

    # Phải chạy từ Proxmox host
    if ! is_proxmox_host; then
        msg_error "Script này phải chạy từ Proxmox VE host shell"
        msg_plain "Nếu muốn cài trực tiếp vào LXC hiện tại, dùng:"
        msg_plain "bash <(curl -fsSL ${INSTALL_SCRIPT_URL})"
        exit 1
    fi

    msg_ok "Đang chạy trên Proxmox VE host"
}

# =============================================================================
# PHASE 1 — Preflight Scan
# =============================================================================
_phase1_preflight() {
    msg_section "PREFLIGHT SCAN — Kiểm tra hệ thống"
    echo -e "  ${C_DIM}Đang quét... vui lòng chờ${CL}\n"

    # ── Group 1: System ───────────────────────────────────────────────────────
    msg_section "① SYSTEM"
    _check_system

    # ── Group 2: Network ──────────────────────────────────────────────────────
    msg_section "② NETWORK"
    _check_network

    # ── Group 3: UDP / NAT ────────────────────────────────────────────────────
    msg_section "③ UDP / NAT  (ảnh hưởng chất lượng kết nối)"
    _check_udp_nat

    # ── Group 4: Tailscale existing ───────────────────────────────────────────
    msg_section "④ TAILSCALE"
    _check_tailscale_existing

    # ── Group 5: Security ─────────────────────────────────────────────────────
    msg_section "⑤ SECURITY"
    _check_security

    # ── Tính verdict ──────────────────────────────────────────────────────────
    _calculate_verdict

    # ── In report ─────────────────────────────────────────────────────────────
    _print_preflight_report
}

# ── Group 1: System checks ────────────────────────────────────────────────────
_check_system() {
    # Proxmox version
    if check_pve_version "7.0"; then
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE + 1 ))
    else
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE - 3 ))
        _add_issue "ABORT" "Proxmox VE version quá cũ — cần nâng cấp lên 7.0+"
    fi

    # Storage
    if check_pve_storage "$CT_DISK"; then
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE + 1 ))
    else
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE - 3 ))
        _add_issue "ABORT" "Không đủ disk space — cần ít nhất ${CT_DISK}GB"
        _add_checklist "Giải phóng disk hoặc xóa snapshots/templates không dùng"
    fi

    # RAM
    if check_ram 256; then
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE + 1 ))
    else
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE - 1 ))
        _add_issue "WARN" "RAM thấp — LXC có thể bị OOM kill"
        _add_checklist "Giảm RAM của VM/LXC khác hoặc tắt bớt services"
    fi

    # CT ID
    if [[ -z "$CTID" ]]; then
        CTID=$(get_free_ctid 100)
    fi
    check_ctid_available "$CTID"

    # Template
    if ensure_template "$CT_OS" "$CT_OS_VERSION"; then
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE + 1 ))
    else
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE - 2 ))
        _add_issue "STOP" "Không download được template ${CT_OS}-${CT_OS_VERSION}"
        _add_checklist "Kiểm tra kết nối internet và pveam update"
    fi
}

# ── Group 2: Network checks ───────────────────────────────────────────────────
_check_network() {
    # Gateway
    if check_gateway; then
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE + 1 ))
    else
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE - 2 ))
        _add_issue "STOP" "Không có default gateway"
        _add_checklist "Kiểm tra cấu hình network trên Proxmox host"
    fi

    # DNS
    if check_dns "controlplane.tailscale.com"; then
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE + 1 ))
    else
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE - 2 ))
        _add_issue "STOP" "DNS không resolve được — Tailscale không kết nối được"
        _add_checklist "Kiểm tra /etc/resolv.conf trên Proxmox host"
    fi

    # HTTPS
    if check_https "https://controlplane.tailscale.com/health"; then
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE + 1 ))
    else
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE - 2 ))
        _add_issue "STOP" "Không reach được Tailscale control plane qua HTTPS"
        _add_checklist "Kiểm tra firewall có block HTTPS outbound không"
    fi

    # Hop count
    count_hops "1.1.1.1" 10
    if [[ "${NET_HOP_COUNT:-0}" != "unknown" ]] && \
       (( ${NET_HOP_COUNT:-0} > 5 )); then
        _add_issue "INFO" \
            "${NET_HOP_COUNT} hops đến internet — có nhiều tầng NAT/firewall"
    fi

    # External IP
    local ext_ip
    ext_ip=$(get_external_ip)
    msg_check "info" "External IP" "${ext_ip}"

    # VLAN detection
    detect_vlan
    if [[ ${#NET_VLANS[@]} -gt 0 ]]; then
        _add_issue "INFO" \
            "VLAN detected: ${NET_VLANS[*]} — xác nhận bridge đúng cho LXC"
        _prompt_bridge_selection
    fi
}

# Hỏi user chọn bridge nếu có VLAN
_prompt_bridge_selection() {
    echo ""
    msg_warn "Phát hiện nhiều network interface — LXC Tailscale nên dùng bridge nào?"

    # Liệt kê bridges có internet
    local bridges=()
    while IFS= read -r iface; do
        bridges+=("$iface")
    done < <(ip link show type bridge 2>/dev/null \
        | awk '/^[0-9]/{gsub(/:/, "", $2); print $2}')

    if [[ ${#bridges[@]} -eq 0 ]]; then
        bridges=("vmbr0")
    fi

    # Thêm info internet status cho từng bridge
    local opts=()
    for br in "${bridges[@]}"; do
        local status="unknown"
        if ip link show "$br" 2>/dev/null | grep -q "UP"; then
            status="UP"
        fi
        opts+=("${br}  [${status}]")
    done

    prompt_menu "Chọn bridge cho LXC Tailscale:" "${opts[@]}"
    CT_BRIDGE="${bridges[$((MENU_CHOICE-1))]}"
    msg_ok "Đã chọn bridge: ${CT_BRIDGE}"
}

# ── Group 3: UDP/NAT checks ───────────────────────────────────────────────────
_check_udp_nat() {
    # UDP 41641 — critical cho P2P
    if check_udp_port 41641 3; then
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE + 2 ))
    else
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE - 2 ))
        _add_issue "WARN" \
            "UDP 41641 bị chặn → Tailscale sẽ dùng DERP relay (latency cao hơn)"
        _add_checklist "Mở UDP 41641 outbound trên firewall upstream"
        _add_impact    "Traffic đi vòng qua DERP server (Singapore/Tokyo)"
        _add_impact    "Latency ~80-200ms thay vì <10ms trên LAN"
    fi

    # UDP 3478 — STUN
    check_udp_port 3478 3
    [[ "$NET_UDP_3478" == "open" ]] && \
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE + 1 ))

    # NAT type
    detect_nat_type 5
    case "${NET_NAT_TYPE:-unknown}" in
        full_cone)
            PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE + 2 ))
            ;;
        restricted)
            PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE + 1 ))
            ;;
        port_restricted)
            PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE - 1 ))
            _add_issue "WARN" "NAT Port-Restricted — P2P không ổn định"
            _add_checklist "Đổi NAT mode về Full Cone trên router nếu có thể"
            ;;
        symmetric)
            PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE - 2 ))
            _add_issue "WARN" \
                "NAT Symmetric — P2P hạn chế, DERP relay bắt buộc"
            _add_impact "ip_forward + Symmetric NAT có thể gây routing loop"
            _add_checklist "Kiểm tra router có hỗ trợ đổi về Full Cone NAT không"
            _add_checklist "Nếu dùng ISP CGNAT → liên hệ ISP hoặc xem xét VPS DERP"
            ;;
        unknown)
            _add_issue "INFO" "Không xác định được NAT type — STUN timeout"
            ;;
    esac

    # TCP 443 DERP fallback
    check_tcp_443 "controlplane.tailscale.com" 5 || {
        PREFLIGHT_SCORE=$(( PREFLIGHT_SCORE - 3 ))
        _add_issue "ABORT" \
            "TCP 443 bị chặn — Tailscale KHÔNG THỂ kết nối được"
        _add_checklist "Mở TCP 443 outbound — đây là port bắt buộc tối thiểu"
    }

    # Xác định connection mode
    NET_CONN_MODE=$(get_connection_mode)
}

# ── Group 4: Tailscale existing check ─────────────────────────────────────────
_check_tailscale_existing() {
    TS_ALREADY_INSTALLED=0
    TS_EXISTING_CTID=""

    # Tìm Tailscale trong các LXC đang chạy
    local ct_list
    ct_list=$(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}')

    local found_cts=()
    for ctid in $ct_list; do
        if pct exec "$ctid" -- which tailscale &>/dev/null 2>&1; then
            local ct_name
            ct_name=$(pct config "$ctid" 2>/dev/null \
                | awk -F': ' '/^hostname/{print $2}')
            local ts_status
            ts_status=$(pct exec "$ctid" -- tailscale status \
                --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' \
                | cut -d'"' -f4 || echo "unknown")
            found_cts+=("CT${ctid} (${ct_name}) — ${ts_status}")
            TS_EXISTING_CTID="$ctid"
        fi
    done

    if [[ ${#found_cts[@]} -gt 0 ]]; then
        TS_ALREADY_INSTALLED=1
        for ct in "${found_cts[@]}"; do
            msg_check "info" "Tailscale found" "$ct"
        done
    else
        msg_check "pass" "Tailscale" "Chưa cài — sẵn sàng cài mới"
    fi
}

# ── Group 5: Security checks ──────────────────────────────────────────────────
_check_security() {
    # TUN device trên host
    if [[ -c /dev/net/tun ]]; then
        msg_check "pass" "TUN device" "/dev/net/tun có sẵn trên host"
    else
        msg_check "warn" "TUN device" \
            "/dev/net/tun không có — script sẽ tạo sau khi tạo LXC"
        _add_issue "INFO" "TUN device sẽ được inject vào LXC config tự động"
    fi

    # ip_forward trên host
    local ipfwd
    ipfwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    if [[ "$ipfwd" == "1" ]]; then
        msg_check "pass" "ip_forward" "Đã enable trên host"
    else
        msg_check "info" "ip_forward" \
            "Chưa enable — sẽ tự enable nếu dùng Subnet Router/Exit Node"
    fi

    # Proxmox firewall
    local pve_fw
    pve_fw=$(pvesh get /nodes/"$(hostname)"/firewall/options 2>/dev/null \
        | grep -o '"enable":[0-9]' | cut -d: -f2 || echo "0")
    if [[ "$pve_fw" == "1" ]]; then
        msg_check "info" "Proxmox Firewall" \
            "Đang bật — cần thêm rule UDP 41641 nếu muốn Direct P2P"
        _add_issue "INFO" \
            "Proxmox Firewall bật — UDP 41641 có thể bị block tại host"
        _add_checklist \
            "Datacenter → Firewall → Add rule: OUT UDP 41641 ACCEPT"
    else
        msg_check "pass" "Proxmox Firewall" "Không bật (không block)"
    fi

    # Unprivileged LXC check
    if [[ "$CT_UNPRIVILEGED" == "1" ]]; then
        msg_check "pass" "LXC mode" \
            "Unprivileged — bảo mật tốt hơn (recommended)"
    else
        msg_check "warn" "LXC mode" \
            "Privileged — attack surface rộng hơn"
    fi
}

# ── Verdict calculation ───────────────────────────────────────────────────────
_ISSUES=()
_IMPACTS=()
_CHECKLIST=()

_add_issue()    { _ISSUES+=("[$1] $2"); }
_add_impact()   { _IMPACTS+=("$1"); }
_add_checklist(){ _CHECKLIST+=("$1"); }

_calculate_verdict() {
    # Kiểm tra có ABORT issue không → ưu tiên cao nhất
    local has_abort=0 has_stop=0
    for issue in "${_ISSUES[@]}"; do
        [[ "$issue" == "[ABORT]"* ]] && has_abort=1
        [[ "$issue" == "[STOP]"*  ]] && has_stop=1
    done

    if [[ $has_abort -eq 1 ]]; then
        PREFLIGHT_VERDICT="ABORT"
    elif [[ $has_stop -eq 1 ]]; then
        PREFLIGHT_VERDICT="STOP"
    elif (( PREFLIGHT_SCORE >= 4 )); then
        PREFLIGHT_VERDICT="GO"
    elif (( PREFLIGHT_SCORE >= 0 )); then
        PREFLIGHT_VERDICT="WARN"
    else
        PREFLIGHT_VERDICT="STOP"
    fi
}

# ── Preflight Report ──────────────────────────────────────────────────────────
_print_preflight_report() {
    echo ""
    msg_divider
    echo ""

    # Connection mode verdict
    local conn_label conn_color
    case "$NET_CONN_MODE" in
        direct)
            conn_label="DIRECT P2P ✓"
            conn_color="${C_OK}"
            ;;
        hybrid)
            conn_label="HYBRID (P2P + DERP)"
            conn_color="${C_WARN}"
            ;;
        derp_only)
            conn_label="DERP RELAY ONLY"
            conn_color="${C_ERR}"
            ;;
        *)
            conn_label="KHÔNG XÁC ĐỊNH"
            conn_color="${C_ERR}"
            ;;
    esac

    # Score + Verdict banner
    case "$PREFLIGHT_VERDICT" in
        GO)
            echo -e "  ${C_OK}${BLD}╔══════════════════════════════════════════════╗${CL}"
            echo -e "  ${C_OK}${BLD}║  ✓  SẴN SÀNG CÀI ĐẶT                       ║${CL}"
            echo -e "  ${C_OK}${BLD}╚══════════════════════════════════════════════╝${CL}"
            ;;
        WARN)
            echo -e "  ${C_WARN}${BLD}╔══════════════════════════════════════════════╗${CL}"
            echo -e "  ${C_WARN}${BLD}║  ⚠  CÀI ĐƯỢC — CÓ MỘT SỐ LƯU Ý           ║${CL}"
            echo -e "  ${C_WARN}${BLD}╚══════════════════════════════════════════════╝${CL}"
            ;;
        STOP)
            echo -e "  ${C_ERR}${BLD}╔══════════════════════════════════════════════╗${CL}"
            echo -e "  ${C_ERR}${BLD}║  ✗  KHÔNG KHUYẾN NGHỊ CÀI LÚC NÀY          ║${CL}"
            echo -e "  ${C_ERR}${BLD}╚══════════════════════════════════════════════╝${CL}"
            ;;
        ABORT)
            echo -e "  ${C_ERR}${BLD}╔══════════════════════════════════════════════╗${CL}"
            echo -e "  ${C_ERR}${BLD}║  ⛔  KHÔNG THỂ TIẾP TỤC — LỖI NGHIÊM TRỌNG ║${CL}"
            echo -e "  ${C_ERR}${BLD}╚══════════════════════════════════════════════╝${CL}"
            ;;
    esac

    echo ""
    echo -e "  ${BLD}Chế độ kết nối dự kiến:${CL}  ${conn_color}${BLD}${conn_label}${CL}"
    echo -e "  ${BLD}Điểm đánh giá        :${CL}  ${PREFLIGHT_SCORE}"
    echo ""

    # Issues
    if [[ ${#_ISSUES[@]} -gt 0 ]]; then
        echo -e "  ${BLD}Vấn đề phát hiện:${CL}"
        for issue in "${_ISSUES[@]}"; do
            local color="${C_INFO}"
            [[ "$issue" == "[WARN]"*  ]] && color="${C_WARN}"
            [[ "$issue" == "[STOP]"*  ]] && color="${C_ERR}"
            [[ "$issue" == "[ABORT]"* ]] && color="${C_ERR}"
            echo -e "    ${color}${issue}${CL}"
        done
        echo ""
    fi

    # Impacts
    if [[ ${#_IMPACTS[@]} -gt 0 ]]; then
        echo -e "  ${BLD}Tác động thực tế nếu cài lúc này:${CL}"
        for impact in "${_IMPACTS[@]}"; do
            echo -e "    ${C_WARN}${ICON_ARROW}${CL} ${impact}"
        done
        echo ""
    fi

    # Checklist
    if [[ ${#_CHECKLIST[@]} -gt 0 ]]; then
        echo -e "  ${BLD}Việc cần làm để cải thiện:${CL}"
        for item in "${_CHECKLIST[@]}"; do
            echo -e "    ${C_INFO}□${CL} ${item}"
        done
        echo ""
    fi

    # Log location
    echo -e "  ${C_DIM}Báo cáo đầy đủ: $(get_log_file)${CL}"
    echo ""
    msg_divider
}

# =============================================================================
# PHASE 2 — User Decision
# =============================================================================
_phase2_user_decision() {
    case "$PREFLIGHT_VERDICT" in
        ABORT)
            echo ""
            msg_error "Không thể tiếp tục — vui lòng fix các lỗi trên trước"
            msg_plain  "Chạy lại script sau khi đã xử lý"
            log_summary
            exit 1
            ;;

        GO)
            echo ""
            if ! prompt_yn "Tiếp tục cài đặt ${APP}?" "Y"; then
                msg_warn "Đã hủy bởi người dùng"
                exit 0
            fi
            ;;

        WARN)
            echo ""
            echo -e "  ${C_WARN}Có một số vấn đề cần lưu ý (xem ở trên).${CL}"
            echo -e "  ${C_WARN}Bạn có thể:${CL}"
            echo -e "  ${C_INFO}[C]${CL} Tiếp tục cài với tình trạng hiện tại"
            echo -e "  ${C_INFO}[R]${CL} Re-scan sau khi tự fix network"
            echo -e "  ${C_INFO}[E]${CL} Thoát để xử lý trước"
            echo ""
            _prompt_cre_decision
            ;;

        STOP)
            echo ""
            echo -e "  ${C_ERR}Script không khuyến nghị cài lúc này.${CL}"
            echo -e "  ${C_ERR}Các vấn đề trên sẽ ảnh hưởng đáng kể đến hiệu quả.${CL}"
            echo ""
            echo -e "  ${C_INFO}[R]${CL} Re-scan sau khi tự fix"
            echo -e "  ${C_INFO}[E]${CL} Thoát"
            echo -e "  ${C_WARN}[F]${CL} Gõ FORCE để cài dù biết rủi ro"
            echo ""
            _prompt_force_decision
            ;;
    esac
}

# Continue / Re-scan / Exit
_prompt_cre_decision() {
    while true; do
        echo -en "  ${C_WARN}?${CL}  Lựa chọn [C/R/E]: "
        read -r choice
        case "${choice^^}" in
            C)
                msg_warn "Tiếp tục cài với tình trạng hiện tại — đã ghi nhận"
                log_write "DECISION" "User chọn Continue (WARN state)"
                break
                ;;
            R)
                msg_info "Re-scan..."
                log_write "DECISION" "User chọn Re-scan"
                # Reset và chạy lại preflight
                PREFLIGHT_SCORE=0
                _ISSUES=() _IMPACTS=() _CHECKLIST=()
                _phase1_preflight
                _phase2_user_decision
                return
                ;;
            E)
                msg_warn "Thoát. Chạy lại script sau khi đã xử lý các vấn đề."
                log_summary
                exit 0
                ;;
            *)
                msg_warn "Nhập C, R hoặc E"
                ;;
        esac
    done
}

# Force / Re-scan / Exit (cho STOP verdict)
_prompt_force_decision() {
    while true; do
        echo -en "  ${C_WARN}?${CL}  Lựa chọn [R/E/FORCE]: "
        read -r choice
        case "${choice}" in
            R|r)
                msg_info "Re-scan..."
                log_write "DECISION" "User chọn Re-scan (STOP state)"
                PREFLIGHT_SCORE=0
                _ISSUES=() _IMPACTS=() _CHECKLIST=()
                _phase1_preflight
                _phase2_user_decision
                return
                ;;
            E|e)
                msg_warn "Thoát."
                log_summary
                exit 0
                ;;
            FORCE)
                msg_warn "⚠ Tiếp tục theo yêu cầu người dùng — rủi ro đã được cảnh báo"
                log_write "DECISION" "User gõ FORCE — bỏ qua cảnh báo STOP"
                break
                ;;
            *)
                msg_warn "Nhập R, E hoặc gõ FORCE để bỏ qua cảnh báo"
                ;;
        esac
    done
}

# =============================================================================
# PHASE 3 — Dynamic Menu
# =============================================================================
_phase3_menu() {
    echo ""

    if [[ "$TS_ALREADY_INSTALLED" -eq 1 ]]; then
        _menu_manage
    else
        _menu_fresh_install
    fi
}

# ── Menu: Cài mới ─────────────────────────────────────────────────────────────
_menu_fresh_install() {
    msg_section "MENU — CÀI MỚI"

    echo ""
    echo -e "  ${C_INFO}[S]${CL}  Simple   — Cài cơ bản, kết nối tailnet, auth thủ công"
    echo -e "  ${C_INFO}[A]${CL}  Advanced — Thêm tùy chọn: Subnet Router, Exit Node, SSH, Auth Key"
    echo -e "  ${C_INFO}[Q]${CL}  Quit"
    echo ""

    while true; do
        echo -en "  ${C_WARN}?${CL}  Lựa chọn [S/A/Q]: "
        read -r choice
        case "${choice^^}" in
            S)
                TS_INSTALL_MODE="simple"
                log_write "MENU" "User chọn Simple install"
                _configure_lxc
                _do_install
                break
                ;;
            A)
                TS_INSTALL_MODE="advanced"
                log_write "MENU" "User chọn Advanced install"
                _configure_lxc
                _configure_advanced
                _do_install
                break
                ;;
            Q)
                msg_warn "Đã hủy"
                exit 0
                ;;
            *)
                msg_warn "Nhập S, A hoặc Q"
                ;;
        esac
    done
}

# ── Menu: Quản lý (đã cài) ────────────────────────────────────────────────────
_menu_manage() {
    msg_section "MENU — QUẢN LÝ TAILSCALE"
    echo -e "  ${C_DIM}Đã phát hiện Tailscale trong: CT${TS_EXISTING_CTID}${CL}"
    echo ""
    echo -e "  ${C_INFO}[M]${CL}  Add / Remove features"
    echo -e "  ${C_INFO}[U]${CL}  Update Tailscale"
    echo -e "  ${C_INFO}[R]${CL}  Re-authenticate (auth key expired)"
    echo -e "  ${C_INFO}[X]${CL}  Uninstall"
    echo -e "  ${C_INFO}[Q]${CL}  Quit"
    echo ""

    while true; do
        echo -en "  ${C_WARN}?${CL}  Lựa chọn [M/U/R/X/Q]: "
        read -r choice
        case "${choice^^}" in
            M) _manage_features;    break ;;
            U) _update_tailscale;   break ;;
            R) _reauthenticate;     break ;;
            X) _uninstall_tailscale; break ;;
            Q) exit 0 ;;
            *) msg_warn "Nhập M, U, R, X hoặc Q" ;;
        esac
    done
}

# =============================================================================
# PHASE 4 — Configure LXC
# =============================================================================
_configure_lxc() {
    msg_section "CẤU HÌNH LXC"

    # Hiển thị defaults
    echo ""
    print_summary "LXC sẽ được tạo" \
        "CT ID"    "$CTID" \
        "Hostname" "$CT_HOSTNAME" \
        "OS"       "${CT_OS} ${CT_OS_VERSION}" \
        "RAM"      "${CT_RAM}MB" \
        "CPU"      "${CT_CPU} core" \
        "Disk"     "${CT_DISK}GB" \
        "Bridge"   "$CT_BRIDGE" \
        "Mode"     "Unprivileged"

    if prompt_yn "Dùng cấu hình mặc định?" "Y"; then
        return 0
    fi

    # Cho phép custom
    prompt_input "CT ID" "$CTID"
    CTID="$REPLY"

    prompt_input "Hostname" "$CT_HOSTNAME"
    CT_HOSTNAME="$REPLY"

    prompt_input "RAM (MB)" "$CT_RAM"
    CT_RAM="$REPLY"

    prompt_input "CPU cores" "$CT_CPU"
    CT_CPU="$REPLY"

    prompt_input "Disk (GB)" "$CT_DISK"
    CT_DISK="$REPLY"

    msg_ok "Cấu hình đã cập nhật"
}

# =============================================================================
# PHASE 4b — Advanced Options
# =============================================================================
_configure_advanced() {
    msg_section "CẤU HÌNH NÂNG CAO"
    echo ""

    # Subnet Router
    if prompt_yn "Bật Subnet Router (expose LAN nội bộ vào tailnet)?" "N"; then
        TS_ENABLE_SUBNET=1
        prompt_input "Subnet routes (vd: 192.168.1.0/24)" ""
        TS_SUBNET_ROUTES="$REPLY"
        msg_ok "Subnet Router: ${TS_SUBNET_ROUTES}"
        _add_post_install_note \
            "Vào Tailscale Admin → Approve subnet route: ${TS_SUBNET_ROUTES}"
    fi

    # Exit Node
    if prompt_yn "Bật Exit Node (route internet qua LXC này)?" "N"; then
        TS_ENABLE_EXITNODE=1
        msg_ok "Exit Node: enabled"
        _add_post_install_note \
            "Vào Tailscale Admin → Approve exit node"
        if [[ "$NET_NAT_TYPE" == "symmetric" ]]; then
            msg_warn "Symmetric NAT detected — Exit Node có thể không hiệu quả"
        fi
    fi

    # Tailscale SSH
    if prompt_yn "Bật Tailscale SSH (quản lý SSH qua tailnet)?" "N"; then
        TS_ENABLE_SSH=1
        msg_ok "Tailscale SSH: enabled"
    fi

    # Auth Key
    echo ""
    echo -e "  ${C_INFO}Tailscale Auth Key${CL} ${C_DIM}(bỏ trống để auth thủ công sau)${CL}"
    echo -e "  ${C_DIM}Tạo tại: https://login.tailscale.com/admin/settings/keys${CL}"
    prompt_input "Auth Key (tskey-auth-...)" ""
    if [[ -n "$REPLY" ]]; then
        TS_AUTHKEY="$REPLY"
        msg_ok "Auth key đã nhập — sẽ authenticate tự động"
    else
        msg_info "Không nhập auth key — cần auth thủ công sau khi cài"
    fi
}

# =============================================================================
# PHASE 5 — Thực hiện cài đặt
# =============================================================================
_do_install() {
    msg_section "BẮT ĐẦU CÀI ĐẶT"
    echo ""

    # Tạo LXC
    msg_info "Bước 1/4: Tạo LXC CT${CTID}"
    create_lxc \
        "$CTID" \
        "$CT_HOSTNAME" \
        "$PVE_TEMPLATE" \
        "$PVE_STORAGE" \
        "$CT_RAM" \
        "$CT_CPU" \
        "$CT_DISK" \
        "$CT_BRIDGE" \
        "$CT_UNPRIVILEGED"

    # Inject TUN device
    msg_info "Bước 2/4: Inject TUN device"
    inject_tun_device "$CTID"

    # Enable ip_forward nếu cần
    if [[ "$TS_ENABLE_SUBNET" -eq 1 ]] || [[ "$TS_ENABLE_EXITNODE" -eq 1 ]]; then
        enable_ip_forward_host
    fi

    # Start LXC
    msg_info "Bước 3/4: Khởi động CT${CTID}"
    start_lxc "$CTID" 30

    # Chạy install script bên trong LXC
    msg_info "Bước 4/4: Cài Tailscale bên trong CT${CTID}"

    local env_vars=(
        "INSTALL_MODE=${TS_INSTALL_MODE}"
        "ENABLE_SUBNET=${TS_ENABLE_SUBNET}"
        "ENABLE_EXITNODE=${TS_ENABLE_EXITNODE}"
        "ENABLE_SSH=${TS_ENABLE_SSH}"
        "SUBNET_ROUTES=${TS_SUBNET_ROUTES}"
        "TS_HOSTNAME=${CT_HOSTNAME}"
    )

    # Auth key — truyền riêng để tránh log
    if [[ -n "$TS_AUTHKEY" ]]; then
        env_vars+=("TS_AUTHKEY=${TS_AUTHKEY}")
    fi

    pct_exec_script "$CTID" "$INSTALL_SCRIPT_URL" "${env_vars[@]}"

    # Set description
    set_lxc_description "$CTID" "$APP" \
        "Mode: ${TS_INSTALL_MODE}
Conn: ${NET_CONN_MODE}
Subnet: ${TS_ENABLE_SUBNET}
ExitNode: ${TS_ENABLE_EXITNODE}
SSH: ${TS_ENABLE_SSH}"

    _phase6_summary
}

# =============================================================================
# PHASE 5b — Manage actions
# =============================================================================
_manage_features() {
    local ctid="${TS_EXISTING_CTID}"
    msg_section "ADD / REMOVE FEATURES — CT${ctid}"
    echo ""

    # Lấy trạng thái hiện tại
    local cur_exitnode cur_subnet cur_ssh
    cur_exitnode=$(pct exec "$ctid" -- \
        tailscale status --json 2>/dev/null \
        | grep -c "ExitNode" || echo "0")
    cur_ssh=$(pct exec "$ctid" -- \
        tailscale status --json 2>/dev/null \
        | grep -c '"SSH"' || echo "0")

    echo -e "  Trạng thái hiện tại:"
    echo -e "  ${C_DIM}Exit Node  : $([[ $cur_exitnode -gt 0 ]] && echo ON || echo OFF)${CL}"
    echo -e "  ${C_DIM}Tailscale SSH: $([[ $cur_ssh -gt 0 ]] && echo ON || echo OFF)${CL}"
    echo ""

    local up_args="tailscale up"

    prompt_yn "Bật Exit Node?" "N" && up_args+=" --advertise-exit-node"
    prompt_yn "Bật Tailscale SSH?" "N" && up_args+=" --ssh"

    if prompt_yn "Bật Subnet Router?" "N"; then
        prompt_input "Subnet routes (vd: 192.168.1.0/24)" ""
        [[ -n "$REPLY" ]] && up_args+=" --advertise-routes=${REPLY}"
    fi

    msg_info "Áp dụng cấu hình mới..."
    pct exec "$ctid" -- bash -c "$up_args --reset"
    msg_ok "Features đã cập nhật"
}

_update_tailscale() {
    local ctid="${TS_EXISTING_CTID}"
    msg_section "UPDATE TAILSCALE — CT${ctid}"

    msg_info "Đang update Tailscale trong CT${ctid}..."
    pct exec "$ctid" -- bash -c \
        "apt-get update -qq && apt-get install -y tailscale 2>&1"
    local new_ver
    new_ver=$(pct exec "$ctid" -- tailscale version 2>/dev/null | head -1)
    msg_ok "Update hoàn tất: ${new_ver}"
}

_reauthenticate() {
    local ctid="${TS_EXISTING_CTID}"
    msg_section "RE-AUTHENTICATE — CT${ctid}"
    echo ""

    echo -e "  ${C_DIM}Tạo auth key tại:${CL}"
    echo -e "  ${C_INFO}https://login.tailscale.com/admin/settings/keys${CL}"
    echo ""
    prompt_input "Auth Key (tskey-auth-...)" ""

    if [[ -n "$REPLY" ]]; then
        pct exec "$ctid" -- tailscale up --authkey="$REPLY" --reset
        msg_ok "Re-authenticated thành công"
    else
        msg_info "Chạy thủ công trong CT${ctid}:"
        msg_plain "pct exec ${ctid} -- tailscale up"
    fi
}

_uninstall_tailscale() {
    local ctid="${TS_EXISTING_CTID}"
    msg_section "UNINSTALL — CT${ctid}"
    echo ""
    msg_warn "Hành động này sẽ:"
    msg_plain "Stop và disable tailscaled service"
    msg_plain "Gỡ Tailscale package (apt purge)"
    msg_plain "Xóa TUN config khỏi LXC"
    msg_plain "Xóa CT${ctid} khỏi tailnet"
    echo ""

    if ! prompt_yn "Xác nhận uninstall Tailscale khỏi CT${ctid}?" "N"; then
        msg_info "Đã hủy"
        return 0
    fi

    msg_info "Đang gỡ cài đặt..."
    pct exec "$ctid" -- bash -c \
        "tailscale logout 2>/dev/null; \
         systemctl stop tailscaled; \
         systemctl disable tailscaled; \
         apt-get purge -y tailscale; \
         apt-get autoremove -y; \
         rm -rf /var/lib/tailscale"

    # Cleanup TUN từ LXC config
    local conf="/etc/pve/lxc/${ctid}.conf"
    if [[ -f "$conf" ]]; then
        sed -i '/tailscale/Id' "$conf"
        sed -i '/lxc.cgroup2.devices.allow.*10:200/d' "$conf"
        sed -i '/lxc.mount.entry.*tun/d' "$conf"
        msg_ok "TUN config đã xóa khỏi ${conf}"
    fi

    msg_ok "Tailscale đã được gỡ khỏi CT${ctid}"
    msg_info "Note: CT${ctid} vẫn còn — bạn có thể xóa thủ công nếu không cần"
}

# =============================================================================
# PHASE 6 — Summary
# =============================================================================
_POST_INSTALL_NOTES=()
_add_post_install_note() { _POST_INSTALL_NOTES+=("$1"); }

_phase6_summary() {
    local lxc_ip
    lxc_ip=$(get_lxc_ip "$CTID" 15)

    local ts_ip=""
    if [[ -n "$TS_AUTHKEY" ]]; then
        ts_ip=$(pct exec "$CTID" -- tailscale ip 2>/dev/null | head -1 || echo "")
    fi

    echo ""
    print_summary "HOÀN TẤT — ${APP} đã cài đặt" \
        "CT ID"       "${CTID}" \
        "Hostname"    "${CT_HOSTNAME}" \
        "LAN IP"      "${lxc_ip:-đang lấy...}" \
        "Tailscale IP" "${ts_ip:-chưa auth}" \
        "Conn Mode"   "${NET_CONN_MODE}" \
        "Mode"        "${TS_INSTALL_MODE}" \
        "Log"         "$(get_log_file)"

    # Auth instruction nếu chưa có key
    if [[ -z "$TS_AUTHKEY" ]]; then
        echo ""
        echo -e "  ${C_WARN}${BLD}Bước tiếp theo — Authenticate Tailscale:${CL}"
        echo ""
        echo -e "  ${C_INFO}1.${CL} Vào CT${CTID}:"
        echo -e "     ${C_DIM}pct exec ${CTID} -- bash${CL}"
        echo ""
        echo -e "  ${C_INFO}2.${CL} Chạy lệnh:"
        local up_cmd="tailscale up"
        [[ "$TS_ENABLE_SUBNET"   -eq 1 ]] && up_cmd+=" --advertise-routes=${TS_SUBNET_ROUTES}"
        [[ "$TS_ENABLE_EXITNODE" -eq 1 ]] && up_cmd+=" --advertise-exit-node"
        [[ "$TS_ENABLE_SSH"      -eq 1 ]] && up_cmd+=" --ssh"
        echo -e "     ${C_DIM}${up_cmd}${CL}"
        echo ""
        echo -e "  ${C_INFO}3.${CL} Mở link hiện ra → Đăng nhập Tailscale account"
        echo -e "     ${BGN}https://login.tailscale.com${CL}"
    fi

    # Post-install notes
    if [[ ${#_POST_INSTALL_NOTES[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${C_WARN}${BLD}Lưu ý sau cài đặt:${CL}"
        for note in "${_POST_INSTALL_NOTES[@]}"; do
            echo -e "  ${C_INFO}□${CL} ${note}"
        done
    fi

    echo ""
    log_summary
}

# =============================================================================
# MAIN — Entry point
# =============================================================================
main() {
    _phase0_entry        # Kiểm tra môi trường + root
    _phase1_preflight    # Scan 5 nhóm
    _phase2_user_decision # Verdict + user confirm
    _phase3_menu         # Dynamic menu
}

main "$@"
