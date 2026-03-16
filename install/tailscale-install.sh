#!/usr/bin/env bash
# =============================================================================
# tailscale-proxmox/install/tailscale-install.sh
#
# Chạy BÊN TRONG LXC — được gọi từ ct/tailscale.sh qua pct_exec_script()
# Không chạy trực tiếp trên Proxmox host!
#
# Nhận biến môi trường từ host:
#   INSTALL_MODE    = simple | advanced
#   ENABLE_SUBNET   = 0 | 1
#   ENABLE_EXITNODE = 0 | 1
#   ENABLE_SSH      = 0 | 1
#   SUBNET_ROUTES   = "192.168.1.0/24,10.0.0.0/8"
#   TS_HOSTNAME     = tên hostname
#   TS_AUTHKEY      = tskey-auth-xxx (optional)
# =============================================================================

# ── Import bash-lib (core only — trong LXC không cần proxmox module) ─────────
BASHLIB_APP_NAME="tailscale-lxc-install"
BASHLIB_LOG_DIR="/var/log"
source <(curl -fsSL \
    https://raw.githubusercontent.com/dainghiavn/bash-lib/main/lib.sh) || {
    echo "[ERROR] Không load được bash-lib" >&2
    exit 1
}

# ── Nhận env vars với giá trị mặc định ───────────────────────────────────────
INSTALL_MODE="${INSTALL_MODE:-simple}"
ENABLE_SUBNET="${ENABLE_SUBNET:-0}"
ENABLE_EXITNODE="${ENABLE_EXITNODE:-0}"
ENABLE_SSH="${ENABLE_SSH:-0}"
SUBNET_ROUTES="${SUBNET_ROUTES:-}"
TS_HOSTNAME="${TS_HOSTNAME:-tailscale}"
TS_AUTHKEY="${TS_AUTHKEY:-}"

# Tailscale apt repo
readonly TS_APT_KEY="/usr/share/keyrings/tailscale-archive-keyring.gpg"
readonly TS_APT_LIST="/etc/apt/sources.list.d/tailscale.list"
readonly TS_SYSCTL_CONF="/etc/sysctl.d/99-tailscale.conf"

# =============================================================================
# STEP 0 — Kiểm tra môi trường LXC
# =============================================================================
_step0_verify_environment() {
    msg_section "Kiểm tra môi trường LXC"

    catch_errors
    check_root

    # Phải chạy trong LXC
    if ! is_lxc_container; then
        msg_warn "Không detect được LXC container — tiếp tục nhưng cẩn thận"
    else
        msg_ok "Đang chạy trong LXC container"
    fi

    # OS check
    detect_os
    case "$OS_ID" in
        debian|ubuntu|raspbian)
            msg_ok "OS: ${OS_ID} ${OS_VERSION} (${OS_CODENAME})"
            ;;
        *)
            msg_error "OS không hỗ trợ: ${OS_ID}"
            msg_plain  "Hỗ trợ: Debian, Ubuntu"
            exit 1
            ;;
    esac

    # TUN device — bắt buộc
    if [[ ! -c /dev/net/tun ]]; then
        msg_error "/dev/net/tun không tồn tại trong LXC này"
        msg_plain  "Kiểm tra lại: ct/tailscale.sh có inject TUN device không"
        msg_plain  "Manual fix trên Proxmox host:"
        msg_plain  "  echo 'lxc.cgroup2.devices.allow: c 10:200 rwm' >> /etc/pve/lxc/\$CTID.conf"
        msg_plain  "  echo 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' >> /etc/pve/lxc/\$CTID.conf"
        exit 1
    fi
    msg_ok "TUN device: /dev/net/tun OK"

    # Internet / control plane check
    # Dùng -sL không -f: server trả 404 là bình thường, 000 mới là lỗi
    local http_code
    http_code=$(curl -sL --max-time 10 \
        -o /dev/null -w "%{http_code}" \
        "https://controlplane.tailscale.com/health" 2>/dev/null \
        | tr -d '[:space:]')

    if [[ -z "$http_code" ]] || [[ "$http_code" == "000" ]]; then
        msg_error "Không reach được Tailscale control plane (timeout/blocked)"
        msg_plain  "Kiểm tra network và DNS"
        msg_plain  "Test thủ công: curl -v https://controlplane.tailscale.com/health"
        exit 1
    fi
    msg_ok "Tailscale control plane: reachable (HTTP ${http_code})"
}

# =============================================================================
# STEP 1 — Chuẩn bị hệ thống
# =============================================================================
_step1_prepare_system() {
    msg_section "Chuẩn bị hệ thống"

    # Update package list
    msg_info "Update package list..."
    $STD apt-get update -qq
    msg_ok "Package list updated"

    # Cài dependencies cần thiết
    msg_info "Cài dependencies..."
    $STD apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        gnupg \
        lsb-release \
        iproute2 \
        iptables \
        procps
    msg_ok "Dependencies installed"

    # Set hostname
    if [[ -n "$TS_HOSTNAME" ]]; then
        hostnamectl set-hostname "$TS_HOSTNAME" 2>/dev/null || \
            echo "$TS_HOSTNAME" > /etc/hostname
        msg_ok "Hostname: ${TS_HOSTNAME}"
    fi
}

# =============================================================================
# STEP 2 — Cài đặt Tailscale
# =============================================================================
_step2_install_tailscale() {
    msg_section "Cài đặt Tailscale"

    # Kiểm tra đã cài chưa
    if command -v tailscale &>/dev/null; then
        local current_ver
        current_ver=$(tailscale version 2>/dev/null | head -1)
        msg_info "Tailscale đã có: ${current_ver} — bỏ qua cài đặt"
        return 0
    fi

    # Detect đúng distro cho Tailscale repo URL
    # Ubuntu và Debian có URL khác nhau:
    #   https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg
    #   https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg
    local ts_distro
    case "$OS_ID" in
        ubuntu)  ts_distro="ubuntu" ;;
        debian)  ts_distro="debian" ;;
        raspbian) ts_distro="debian" ;;
        *)       ts_distro="debian" ;;  # fallback
    esac

    local ts_base_url="https://pkgs.tailscale.com/stable/${ts_distro}/${OS_CODENAME}"

    msg_info "Distro: ${ts_distro} ${OS_CODENAME}"

    # Thêm GPG key — dùng -sL không -f (tránh exit 22 khi redirect)
    msg_info "Thêm Tailscale GPG key..."
    local gpg_url="${ts_base_url}.noarmor.gpg"
    if ! curl -sL --max-time 30 "$gpg_url" \
        | tee "$TS_APT_KEY" > /dev/null; then
        msg_error "Không download được GPG key: ${gpg_url}"
        msg_plain  "Kiểm tra URL: curl -I ${gpg_url}"
        exit 1
    fi

    # Verify key hợp lệ (file binary, không phải HTML error)
    if ! file "$TS_APT_KEY" 2>/dev/null | grep -qi "PGP\|GPG\|data"; then
        # Thử đọc nội dung xem có phải error page không
        if grep -qi "not found\|error\|404" "$TS_APT_KEY" 2>/dev/null; then
            msg_error "GPG key URL không hợp lệ: ${gpg_url}"
            msg_plain  "OS_CODENAME='${OS_CODENAME}' có thể không đúng"
            exit 1
        fi
    fi
    msg_ok "GPG key added: ${TS_APT_KEY}"

    # Thêm apt repository
    msg_info "Thêm Tailscale apt repository..."
    local list_url="${ts_base_url}.tailscale-keyring.list"
    if ! curl -sL --max-time 30 "$list_url" \
        | tee "$TS_APT_LIST" > /dev/null; then
        msg_error "Không download được apt list: ${list_url}"
        exit 1
    fi
    msg_ok "Repository added: ${TS_APT_LIST}"

    # Install
    msg_info "Cài tailscale package..."
    $STD apt-get update -qq
    $STD apt-get install -y tailscale
    msg_ok "Tailscale installed: $(tailscale version | head -1)"
}

# =============================================================================
# STEP 3 — Cấu hình hệ thống
# =============================================================================
_step3_configure_system() {
    msg_section "Cấu hình hệ thống"

    # ip_forward — cần cho Subnet Router và Exit Node
    if [[ "$ENABLE_SUBNET" == "1" ]] || [[ "$ENABLE_EXITNODE" == "1" ]]; then
        msg_info "Enable ip_forward (cần cho Subnet Router/Exit Node)..."
        cat > "$TS_SYSCTL_CONF" <<EOF
# Tailscale — ip_forward
# Generated by tailscale-proxmox installer
net.ipv4.ip_forward          = 1
net.ipv6.conf.all.forwarding = 1
EOF
        sysctl -p "$TS_SYSCTL_CONF" &>/dev/null
        msg_ok "ip_forward: enabled"
    else
        msg_info "ip_forward: không cần (Simple mode)"
    fi

    # iptables — cho phép Tailscale forward traffic
    if [[ "$ENABLE_SUBNET" == "1" ]] || [[ "$ENABLE_EXITNODE" == "1" ]]; then
        msg_info "Cấu hình iptables cho forwarding..."
        # Accept forwarded traffic qua Tailscale interface
        iptables -I FORWARD -i tailscale0 -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD -o tailscale0 -j ACCEPT 2>/dev/null || true
        # Masquerade traffic ra ngoài
        iptables -t nat -I POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || true

        # Lưu iptables rules để persist sau reboot
        if command -v iptables-save &>/dev/null; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi

        # Cài iptables-persistent nếu chưa có
        if ! dpkg -l iptables-persistent &>/dev/null; then
            echo iptables-persistent iptables-persistent/autosave_v4 \
                boolean true | debconf-set-selections
            $STD apt-get install -y iptables-persistent
        fi
        msg_ok "iptables configured"
    fi
}

# =============================================================================
# STEP 4 — Start Tailscale service
# =============================================================================
_step4_start_service() {
    msg_section "Khởi động Tailscale service"

    # Enable và start tailscaled
    msg_info "Enable tailscaled service..."
    $STD systemctl enable tailscaled
    $STD systemctl start tailscaled

    # Chờ service ready
    local max_wait=15
    local elapsed=0
    while (( elapsed < max_wait )); do
        if systemctl is-active --quiet tailscaled; then
            msg_ok "tailscaled service: running"
            return 0
        fi
        sleep 1
        (( elapsed++ )) || true
    done

    # Service chưa lên
    msg_error "tailscaled không start được sau ${max_wait}s"
    msg_plain  "Kiểm tra: journalctl -u tailscaled -n 50"
    return 1
}

# =============================================================================
# STEP 5 — Authenticate và cấu hình Tailscale
# =============================================================================
_step5_configure_tailscale() {
    msg_section "Cấu hình Tailscale"

    # Build tailscale up arguments
    local up_args=()

    # Subnet Router
    if [[ "$ENABLE_SUBNET" == "1" ]] && [[ -n "$SUBNET_ROUTES" ]]; then
        up_args+=("--advertise-routes=${SUBNET_ROUTES}")
        msg_info "Subnet routes: ${SUBNET_ROUTES}"
    fi

    # Exit Node
    if [[ "$ENABLE_EXITNODE" == "1" ]]; then
        up_args+=("--advertise-exit-node")
        msg_info "Exit Node: enabled"
    fi

    # Tailscale SSH
    if [[ "$ENABLE_SSH" == "1" ]]; then
        up_args+=("--ssh")
        msg_info "Tailscale SSH: enabled"
    fi

    # Hostname
    if [[ -n "$TS_HOSTNAME" ]]; then
        up_args+=("--hostname=${TS_HOSTNAME}")
    fi

    # Auth với key nếu có
    if [[ -n "$TS_AUTHKEY" ]]; then
        msg_info "Authenticating với auth key..."
        up_args+=("--authkey=${TS_AUTHKEY}")

        if tailscale up "${up_args[@]}" 2>&1; then
            msg_ok "Authenticated thành công!"
            _verify_auth
        else
            msg_error "Auth key thất bại — có thể key đã hết hạn hoặc sai"
            msg_plain  "Auth thủ công: tailscale up"
        fi
    else
        # Không có auth key → interactive auth với retry
        up_args+=("--accept-routes")
        _auth_interactive "${up_args[@]}"
    fi
}

# ── Interactive auth với timeout + retry + rollback ───────────────────────────
_auth_interactive() {
    local up_args=("$@")

    local max_retries=3
    local url_poll_timeout=15       # giây chờ URL xuất hiện
    local auth_wait_timeout=300     # 5 phút chờ user auth
    local attempt=0

    while (( attempt < max_retries )); do
        (( attempt++ )) || true

        echo ""
        if (( attempt > 1 )); then
            msg_info "Retry lần ${attempt}/${max_retries}..."
        fi

        # ── Lấy auth URL ──────────────────────────────────────────────────────
        local auth_url=""
        local tmp_out
        tmp_out=$(mktemp /tmp/ts-auth-XXXXXX)

        # Chạy tailscale up background để lấy URL
        # KHÔNG dùng --reset: chỉ cần URL, không reset state
        # KHÔNG kill sau khi lấy URL: để tailscaled tự handle auth flow
        tailscale up "${up_args[@]}" > "$tmp_out" 2>&1 &
        local ts_pid=$!

        # Poll file chờ URL xuất hiện (tối đa url_poll_timeout giây)
        local elapsed=0
        while (( elapsed < url_poll_timeout )); do
            auth_url=$(grep -oP 'https://login\.tailscale\.com/a/\S+' \
                "$tmp_out" 2>/dev/null | head -1 || true)
            [[ -n "$auth_url" ]] && break
            sleep 1
            (( elapsed++ )) || true
        done
        echo ""
        echo -e "  ${BLD}${CY}╔══════════════════════════════════════════════╗${CL}"
        echo -e "  ${BLD}${CY}║  🔐  XÁC THỰC TAILSCALE                     ║${CL}"
        echo -e "  ${BLD}${CY}╚══════════════════════════════════════════════╝${CL}"
        echo ""

        if [[ -n "$auth_url" ]]; then
            echo -e "  ${C_WARN}${BLD}Mở URL sau trên browser để đăng nhập:${CL}"
            echo ""
            echo -e "  ${C_INFO}${BLD}${auth_url}${CL}"
            echo ""
            echo -e "  ${C_DIM}Timeout: ${auth_wait_timeout}s — Script tự tiếp tục sau khi bạn đăng nhập${CL}"
            echo ""
            log_write "AUTH_URL" "${auth_url}"
        else
            msg_warn "Không lấy được URL tự động"
            msg_plain "Chạy thủ công: tailscale up"
            _auth_show_manual_cmd "${up_args[@]}"
            _auth_skip_handler
            return
        fi

        # ── Chờ auth thành công với countdown ────────────────────────────────
        local auth_done=false
        local wait_elapsed=0

        while (( wait_elapsed < auth_wait_timeout )); do

            # Cách đơn giản nhất: tailscale ip -4 trả về IP khi đã auth
            # Trả về empty/error khi chưa auth → không cần parse JSON
            local ts_ip
            ts_ip=$(tailscale ip -4 2>/dev/null || true)

            if [[ -n "$ts_ip" ]] && [[ "$ts_ip" =~ ^100\. ]]; then
                auth_done=true
                break
            fi

            # Lấy trạng thái hiện tại để hiển thị
            local ts_state
            ts_state=$(tailscale status 2>/dev/null | head -1 \
                | grep -oP '(?<=Status: )\w+' || \
                tailscale status --json 2>/dev/null \
                | grep -o '"BackendState":"[^"]*"' \
                | cut -d'"' -f4 2>/dev/null || echo "connecting")

            # Countdown cập nhật mỗi 3 giây
            local remaining=$(( auth_wait_timeout - wait_elapsed ))
            local mins=$(( remaining / 60 ))
            local secs=$(( remaining % 60 ))

            if (( mins > 0 )); then
                printf "\r  ${C_DIM}⏱  Chờ auth... còn %dm%ds  [%s]${CL}     " \
                    "$mins" "$secs" "${ts_state:-waiting}"
            else
                printf "\r  ${C_WARN}⏱  Chờ auth... còn %ds  [%s]${CL}     " \
                    "$secs" "${ts_state:-waiting}"
            fi

            sleep 3
            (( wait_elapsed += 3 )) || true
        done

        printf "\r%60s\r" ""   # Clear countdown line

        # Cleanup background process
        kill "$ts_pid" 2>/dev/null || true
        wait "$ts_pid" 2>/dev/null || true
        rm -f "$tmp_out"

        # ── Xử lý kết quả ────────────────────────────────────────────────────
        if $auth_done; then
            echo ""
            msg_ok "Xác thực thành công!"
            _verify_auth
            return 0
        fi

        # Auth timeout — hỏi user
        echo ""
        local remaining_retries=$(( max_retries - attempt ))
        _auth_timeout_menu "$attempt" "$max_retries" "$remaining_retries" \
            "${up_args[@]}"
        local menu_result=$?

        case $menu_result in
            0)  # Retry — tiếp tục loop
                continue
                ;;
            1)  # Skip — cài xong không auth
                _auth_skip_handler
                return 0
                ;;
            2)  # Quit — rollback
                _auth_quit_rollback
                exit 0
                ;;
        esac

    done

    # Hết retry — auto skip
    echo ""
    msg_warn "Đã thử ${max_retries} lần nhưng không xác thực được"
    _auth_skip_handler
}

# ── Hiển thị menu khi timeout ─────────────────────────────────────────────────
_auth_timeout_menu() {
    local attempt="$1"
    local max="$2"
    local remaining="$3"
    shift 3

    echo -e "  ${C_WARN}⏱  Timeout — Chưa xác thực được sau 5 phút${CL}"
    echo ""

    if (( remaining > 0 )); then
        echo -e "  ${C_INFO}[R]${CL}  Retry — lấy URL mới ${C_DIM}(còn ${remaining} lần)${CL}"
    else
        echo -e "  ${C_DIM}[R]  Retry — không còn lần thử nào${CL}"
    fi
    echo -e "  ${C_INFO}[S]${CL}  Skip  — hoàn tất cài đặt, auth thủ công sau"
    echo -e "  ${C_INFO}[Q]${CL}  Quit  — thoát và rollback cấu hình"
    echo ""

    while true; do
        echo -en "  ${C_WARN}?${CL}  Lựa chọn [$(( remaining > 0 ))R/S/Q]: "
        read -r choice
        case "${choice^^}" in
            R)
                if (( remaining > 0 )); then
                    log_write "AUTH" "User chọn Retry (lần ${attempt}/${max})"
                    return 0
                else
                    msg_warn "Không còn lần retry — chọn S hoặc Q"
                fi
                ;;
            S)
                log_write "AUTH" "User chọn Skip auth"
                return 1
                ;;
            Q)
                log_write "AUTH" "User chọn Quit + rollback"
                return 2
                ;;
            *)
                msg_warn "Nhập R, S hoặc Q"
                ;;
        esac
    done
}

# ── Skip: hoàn tất nhưng chưa auth ───────────────────────────────────────────
_auth_skip_handler() {
    local up_cmd="tailscale up --accept-routes"
    [[ "$ENABLE_SUBNET"   == "1" ]] && \
        up_cmd+=" --advertise-routes=${SUBNET_ROUTES}"
    [[ "$ENABLE_EXITNODE" == "1" ]] && \
        up_cmd+=" --advertise-exit-node"
    [[ "$ENABLE_SSH"      == "1" ]] && \
        up_cmd+=" --ssh"

    echo ""
    echo -e "  ${C_WARN}${BLD}Tailscale đã cài — cần auth để hoạt động${CL}"
    echo ""
    echo -e "  Chạy lệnh sau bất cứ lúc nào để auth:"
    echo ""
    echo -e "  ${C_INFO}${up_cmd}${CL}"
    echo ""
    echo -e "  ${C_DIM}Hoặc dùng auth key tại:${CL}"
    echo -e "  ${C_INFO}https://login.tailscale.com/admin/settings/keys${CL}"
    echo ""
    log_write "AUTH_SKIP" "Tailscale installed but not authenticated. Manual cmd: ${up_cmd}"
}

# ── Quit + Rollback ───────────────────────────────────────────────────────────
_auth_quit_rollback() {
    echo ""
    msg_info "Đang rollback cấu hình Tailscale..."

    # Stop và disable service
    systemctl stop tailscaled 2>/dev/null || true
    systemctl disable tailscaled 2>/dev/null || true
    msg_ok "Service stopped"

    # Xóa state files (giữ lại package để có thể dùng lại)
    rm -rf /var/lib/tailscale 2>/dev/null || true
    rm -f /etc/tailscale-proxmox/install-info 2>/dev/null || true
    msg_ok "State files cleared"

    # Xóa sysctl config nếu đã tạo
    rm -f /etc/sysctl.d/99-tailscale.conf 2>/dev/null || true

    echo ""
    echo -e "  ${C_WARN}Rollback hoàn tất.${CL}"
    echo -e "  ${C_DIM}Package Tailscale vẫn còn — chạy lại script khi sẵn sàng.${CL}"
    echo ""
    log_write "ROLLBACK" "User quit — state cleared, package retained"
}

# ── In lệnh auth thủ công ─────────────────────────────────────────────────────
_auth_show_manual_cmd() {
    local up_cmd="tailscale up --accept-routes"
    [[ "$ENABLE_SUBNET"   == "1" ]] && \
        up_cmd+=" --advertise-routes=${SUBNET_ROUTES}"
    [[ "$ENABLE_EXITNODE" == "1" ]] && \
        up_cmd+=" --advertise-exit-node"
    [[ "$ENABLE_SSH"      == "1" ]] && \
        up_cmd+=" --ssh"

    echo ""
    echo -e "  ${C_DIM}Lệnh auth thủ công:${CL}"
    echo -e "  ${C_INFO}${up_cmd}${CL}"
    echo ""
}

# Verify kết nối sau auth
_verify_auth() {
    local max_wait=20
    local elapsed=0

    msg_info "Kiểm tra kết nối tailnet..."
    while (( elapsed < max_wait )); do
        local ts_ip
        ts_ip=$(tailscale ip -4 2>/dev/null || true)

        if [[ -n "$ts_ip" ]] && [[ "$ts_ip" =~ ^100\. ]]; then
            local ts_ver
            ts_ver=$(tailscale version 2>/dev/null | head -1)
            local ts_hostname
            ts_hostname=$(tailscale status 2>/dev/null \
                | awk 'NR==2{print $2}' || echo "")
            local derp_region
            derp_region=$(tailscale netcheck 2>/dev/null \
                | grep -i "preferred DERP" \
                | awk '{print $NF}' || echo "unknown")

            echo ""
            msg_ok "Tailscale connected!"
            msg_plain "Tailscale IP  : ${ts_ip}"
            msg_plain "Hostname      : ${ts_hostname:-$(hostname)}"
            msg_plain "Version       : ${ts_ver}"
            msg_plain "DERP region   : ${derp_region}"
            return 0
        fi

        sleep 1
        (( elapsed++ )) || true
    done

    msg_warn "Tailscale chưa kết nối được sau ${max_wait}s"
    msg_plain "Kiểm tra: tailscale status"
}

# =============================================================================
# STEP 6 — Hardening & cleanup
# =============================================================================
_step6_hardening() {
    msg_section "Hardening & Cleanup"

    # Tắt password auth SSH (nếu sshd có) — dùng Tailscale SSH thay thế
    if [[ "$ENABLE_SSH" == "1" ]] && [[ -f /etc/ssh/sshd_config ]]; then
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' \
            /etc/ssh/sshd_config 2>/dev/null || true
        systemctl reload sshd 2>/dev/null || true
        msg_ok "SSH password auth: disabled (dùng Tailscale SSH)"
    fi

    # Tắt root login trực tiếp
    if [[ -f /etc/ssh/sshd_config ]]; then
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' \
            /etc/ssh/sshd_config 2>/dev/null || true
    fi

    # Cleanup apt cache
    msg_info "Cleanup..."
    $STD apt-get clean
    $STD apt-get autoremove -y
    rm -rf /var/lib/apt/lists/*
    msg_ok "Cleanup done"

    # Ghi thông tin cài đặt
    mkdir -p /etc/tailscale-proxmox
    cat > /etc/tailscale-proxmox/install-info <<EOF
# Tailscale Install Info
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
INSTALL_MODE="${INSTALL_MODE}"
ENABLE_SUBNET="${ENABLE_SUBNET}"
ENABLE_EXITNODE="${ENABLE_EXITNODE}"
ENABLE_SSH="${ENABLE_SSH}"
SUBNET_ROUTES="${SUBNET_ROUTES}"
HOSTNAME="${TS_HOSTNAME}"
TAILSCALE_VERSION="$(tailscale version 2>/dev/null | head -1)"
EOF
    msg_ok "Install info: /etc/tailscale-proxmox/install-info"
}

# =============================================================================
# STEP 7 — Final summary trong LXC
# =============================================================================
_step7_summary() {
    local ts_ip ts_ver conn_status

    ts_ip=$(tailscale ip -4 2>/dev/null || echo "chưa auth")
    ts_ver=$(tailscale version 2>/dev/null | head -1 || echo "unknown")
    conn_status=$(tailscale status 2>/dev/null | head -1 || echo "not connected")

    echo ""
    print_summary "Tailscale LXC — Cài đặt hoàn tất" \
        "Version"      "${ts_ver}" \
        "Tailscale IP" "${ts_ip}" \
        "Mode"         "${INSTALL_MODE}" \
        "Subnet Router" "$([[ $ENABLE_SUBNET   == 1 ]] && echo "ON: ${SUBNET_ROUTES}" || echo "OFF")" \
        "Exit Node"    "$([[ $ENABLE_EXITNODE  == 1 ]] && echo "ON" || echo "OFF")" \
        "TS SSH"       "$([[ $ENABLE_SSH       == 1 ]] && echo "ON" || echo "OFF")" \
        "Log"          "$(get_log_file)"

    # Hiển thị hướng dẫn nếu chưa auth
    if [[ -z "$TS_AUTHKEY" ]]; then
        echo ""
        echo -e "  ${C_WARN}${BLD}══ AUTH THỦ CÔNG — CẦN THỰC HIỆN NGAY ══${CL}"
        echo ""
        echo -e "  Chạy lệnh sau trong LXC này:"
        echo ""

        local up_cmd="  tailscale up"
        [[ "$ENABLE_SUBNET"   == "1" ]] && [[ -n "$SUBNET_ROUTES" ]] && \
            up_cmd+=" \\\n    --advertise-routes=${SUBNET_ROUTES}"
        [[ "$ENABLE_EXITNODE" == "1" ]] && \
            up_cmd+=" \\\n    --advertise-exit-node"
        [[ "$ENABLE_SSH"      == "1" ]] && \
            up_cmd+=" \\\n    --ssh"
        up_cmd+=" \\\n    --accept-routes"

        echo -e "  ${C_INFO}${up_cmd}${CL}"
        echo ""
        echo -e "  Sau đó mở link hiện ra trên browser để đăng nhập."
        echo ""
        echo -e "  ${C_DIM}Tạo auth key tại:${CL}"
        echo -e "  ${C_INFO}https://login.tailscale.com/admin/settings/keys${CL}"
        echo ""
    fi

    # Advanced mode notes
    if [[ "$INSTALL_MODE" == "advanced" ]]; then
        if [[ "$ENABLE_SUBNET" == "1" ]] || [[ "$ENABLE_EXITNODE" == "1" ]]; then
            echo ""
            echo -e "  ${C_WARN}${BLD}Lưu ý cho Admin Tailscale:${CL}"
            [[ "$ENABLE_SUBNET"   == "1" ]] && \
                echo -e "  ${C_INFO}□${CL} Approve subnet route tại admin console"
            [[ "$ENABLE_EXITNODE" == "1" ]] && \
                echo -e "  ${C_INFO}□${CL} Approve exit node tại admin console"
            echo -e "  ${C_INFO}→${CL} https://login.tailscale.com/admin/machines"
        fi
    fi

    echo ""
    msg_ok "tailscale-install.sh hoàn tất!"
    log_summary
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    header_info "Tailscale Install"

    echo -e "  ${C_DIM}Mode     : ${INSTALL_MODE}${CL}"
    echo -e "  ${C_DIM}Subnet   : ${ENABLE_SUBNET}${CL}"
    echo -e "  ${C_DIM}ExitNode : ${ENABLE_EXITNODE}${CL}"
    echo -e "  ${C_DIM}SSH      : ${ENABLE_SSH}${CL}"
    echo -e "  ${C_DIM}Log      : $(get_log_file)${CL}"
    echo ""

    _step0_verify_environment   # Kiểm tra LXC, OS, TUN, internet
    _step1_prepare_system       # apt update, dependencies, hostname
    _step2_install_tailscale    # Thêm repo + cài package
    _step3_configure_system     # ip_forward, iptables nếu cần
    _step4_start_service        # systemctl enable + start
    _step5_configure_tailscale  # tailscale up + auth
    _step6_hardening            # SSH hardening + cleanup
    _step7_summary              # In kết quả cuối
}

main "$@"
