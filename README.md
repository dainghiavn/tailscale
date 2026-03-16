# Tailscale Proxmox Installer

> Cài đặt Tailscale tự động vào LXC container trên Proxmox VE  
> Tích hợp **Preflight Scan** — phân tích mạng và đưa ra khuyến nghị trước khi cài

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Proxmox VE](https://img.shields.io/badge/Proxmox%20VE-7.0%2B-orange)](https://www.proxmox.com)
[![Tailscale](https://img.shields.io/badge/Tailscale-latest-blue)](https://tailscale.com)

---

## 📋 Mục lục

- [Yêu cầu](#-yêu-cầu)
- [Cài đặt nhanh](#-cài-đặt-nhanh)
- [Tính năng](#-tính-năng)
- [Preflight Scan](#-preflight-scan)
- [Chế độ cài đặt](#-chế-độ-cài-đặt)
- [Cấu trúc repo](#-cấu-trúc-repo)
- [Cách hoạt động](#-cách-hoạt-động)
- [Sau khi cài](#-sau-khi-cài)
- [Quản lý sau cài đặt](#-quản-lý-sau-cài-đặt)
- [Gỡ lỗi](#-gỡ-lỗi)
- [FAQ](#-faq)
- [License](#-license)

---

## ✅ Yêu cầu

| Yêu cầu | Tối thiểu |
|---|---|
| Proxmox VE | 7.0+ |
| OS LXC | Debian 12 (mặc định) |
| RAM host | 256MB free |
| Disk | 2GB free trên storage |
| Internet | HTTPS outbound bắt buộc |
| Quyền | root trên Proxmox host |

---

## 🚀 Cài đặt nhanh

Chạy lệnh sau trên **Proxmox VE shell**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dainghiavn/tailscale/main/ct/tailscale.sh)"
```

> ⚠️ **Lưu ý:** Chạy trên Proxmox host shell — không phải bên trong LXC

---

## ✨ Tính năng

### Preflight Scan thông minh
- Kiểm tra **5 nhóm** trước khi cài: System, Network, UDP/NAT, Tailscale, Security
- Phát hiện **NAT type** và dự đoán chất lượng kết nối P2P
- Đưa ra **khuyến nghị cụ thể** theo tình trạng hệ thống
- Cho phép **Re-scan** sau khi kỹ thuật viên tự xử lý

### Dynamic Menu
- **Chưa cài:** Menu Simple / Advanced
- **Đã cài:** Menu Add-Remove / Update / Re-auth / Uninstall
- Không hiển thị tùy chọn không phù hợp với trạng thái hiện tại

### LXC Isolated
- Luôn tạo **LXC mới** — không cài chung với service khác
- Tự động inject **TUN device** vào LXC config
- Hỗ trợ **Unprivileged LXC** (bảo mật tốt hơn)

### Chế độ kết nối
| Mode | Điều kiện | Latency |
|---|---|---|
| 🟢 Direct P2P | UDP 41641 open + NAT tốt | < 10ms |
| 🟡 Hybrid | UDP partial hoặc NAT restricted | Không ổn định |
| 🔴 DERP Only | UDP blocked hoặc Symmetric NAT | 80-200ms |

---

## 🔍 Preflight Scan

Script thực hiện **5 nhóm kiểm tra** và in báo cáo trước khi cài:

```
── ① SYSTEM ────────────────────────────────────────
[✓] Proxmox VE 8.2.4         OK
[✓] Disk: 48GB free           OK  (cần 2GB)
[✓] CT ID 200                 OK  (chưa dùng)
[⚠] RAM: 380MB free          WARN (khuyến nghị 512MB+)

── ② NETWORK ───────────────────────────────────────
[✓] Gateway: 192.168.1.1     OK
[✓] DNS resolve               OK
[✓] HTTPS controlplane        OK
[ℹ] Hop count: 3 hops        INFO (có firewall trung gian)

── ③ UDP / NAT ─────────────────────────────────────
[✗] UDP 41641                 BLOCKED ← firewall chặn
[⚠] NAT type: Symmetric      WARN    ← P2P hạn chế
[✓] TCP 443 DERP fallback     OK

── ④ TAILSCALE ─────────────────────────────────────
[✓] Chưa cài                  Fresh install mode

── ⑤ SECURITY ──────────────────────────────────────
[✓] Unprivileged LXC          OK
[ℹ] Proxmox Firewall: ON     INFO (cần thêm rule UDP 41641)
```

### Verdict 4 cấp

| Verdict | Điều kiện | Hành động |
|---|---|---|
| 🟢 **GO** | Score cao, không có lỗi | Tiếp tục cài ngay |
| 🟡 **WARN** | Có vấn đề nhỏ | Hỏi C/R/E (Continue/Rescan/Exit) |
| 🔴 **STOP** | Vấn đề nghiêm trọng | Yêu cầu gõ `FORCE` để bỏ qua |
| ⛔ **ABORT** | Lỗi critical | Tự động dừng, không có option |

---

## 📦 Chế độ cài đặt

### Simple Mode
Cài đặt cơ bản — kết nối vào tailnet, auth thủ công sau.

```
✓ Cài Tailscale package
✓ Start tailscaled service
✓ Inject TUN device
✓ Hướng dẫn tailscale up
```

### Advanced Mode
Đầy đủ tùy chọn cho môi trường phức tạp.

```
✓ Tất cả của Simple
+ Subnet Router  — expose LAN nội bộ vào tailnet
+ Exit Node      — route internet traffic qua LXC
+ Tailscale SSH  — quản lý SSH qua tailnet
+ Auth Key       — authenticate tự động (không cần thủ công)
+ ip_forward     — tự động enable khi cần
+ iptables rules — persist sau reboot
```

### Manage Mode (đã cài)
Xuất hiện khi phát hiện Tailscale đã được cài trong LXC.

```
[M] Add/Remove features  — toggle Subnet/ExitNode/SSH
[U] Update               — apt upgrade tailscale
[R] Re-authenticate      — khi auth key hết hạn
[X] Uninstall            — gỡ sạch, revert TUN config
```

---

## 📁 Cấu trúc repo

```
tailscale/
├── ct/
│   └── tailscale.sh              ← Entry point (chạy trên Proxmox host)
├── install/
│   └── tailscale-install.sh      ← Install script (chạy bên trong LXC)
├── README.md
└── LICENSE
```

### Dependency
Script dùng [bash-lib](https://github.com/dainghiavn/bash-lib) — thư viện helper dùng chung:

```bash
# Tự động import trong script — không cần làm gì thêm
source <(curl -fsSL https://raw.githubusercontent.com/dainghiavn/bash-lib/main/lib.sh)
```

---

## ⚙️ Cách hoạt động

```
Proxmox Host Shell
│
├─ ct/tailscale.sh
│   ├── Phase 0: Detect môi trường + check root
│   ├── Phase 1: Preflight scan (5 nhóm)
│   ├── Phase 2: Verdict + User decision (C/R/E/FORCE)
│   ├── Phase 3: Dynamic menu theo trạng thái
│   ├── Phase 4: Cấu hình LXC + Advanced options
│   ├── Phase 5: Tạo LXC → Inject TUN → Start
│   │            └── gọi install/tailscale-install.sh bên trong LXC
│   └── Phase 6: Summary + hướng dẫn auth
│
└─ install/tailscale-install.sh (chạy trong LXC)
    ├── Step 0: Verify LXC environment
    ├── Step 1: apt update + dependencies
    ├── Step 2: Thêm Tailscale repo + cài package
    ├── Step 3: ip_forward + iptables nếu cần
    ├── Step 4: systemctl enable + start tailscaled
    ├── Step 5: tailscale up + authenticate
    ├── Step 6: SSH hardening + cleanup
    └── Step 7: Summary + hướng dẫn
```

---

## 🔐 Sau khi cài

### Auth thủ công (không dùng auth key)

```bash
# Vào LXC
pct exec <CTID> -- bash

# Simple mode
tailscale up

# Advanced mode — ví dụ đầy đủ
tailscale up \
  --advertise-routes=192.168.1.0/24 \
  --advertise-exit-node \
  --ssh \
  --accept-routes

# Mở link hiện ra trên browser để đăng nhập
```

### Approve trên Admin Console (Advanced mode)

Sau khi auth, vào [Tailscale Admin](https://login.tailscale.com/admin/machines):

```
Subnet Router → Click "..." → Approve subnet routes
Exit Node     → Click "..." → Approve as exit node
```

### Kiểm tra kết nối

```bash
# Xem trạng thái
pct exec <CTID> -- tailscale status

# Xem IP
pct exec <CTID> -- tailscale ip

# Kiểm tra network quality
pct exec <CTID> -- tailscale netcheck

# Debug đầy đủ
pct exec <CTID> -- tailscale debug report
```

---

## 🛠️ Quản lý sau cài đặt

Chạy lại script để vào menu quản lý:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dainghiavn/tailscale/main/ct/tailscale.sh)"
```

Script tự động phát hiện Tailscale đã cài và hiển thị menu quản lý.

### Thao tác thủ công trong LXC

```bash
# Vào LXC shell
pct exec <CTID> -- bash

# Xem logs
journalctl -u tailscaled -f

# Restart service
systemctl restart tailscaled

# Update thủ công
apt-get update && apt-get install -y tailscale

# Logout khỏi tailnet
tailscale logout
```

---

## 🔧 Gỡ lỗi

### UDP 41641 bị chặn

```bash
# Test từ LXC
pct exec <CTID> -- bash -c \
  "echo | nc -u -w3 udp.tailscale.com 41641 && echo OPEN || echo BLOCKED"

# Fix trên Proxmox Firewall
# Datacenter → Firewall → Add:
# Direction: out, Protocol: udp, Dest port: 41641, Action: ACCEPT
```

### TUN device không có

```bash
# Kiểm tra
pct exec <CTID> -- ls -la /dev/net/tun

# Fix thủ công — chạy trên Proxmox host
echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> /etc/pve/lxc/<CTID>.conf
echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" \
  >> /etc/pve/lxc/<CTID>.conf
pct restart <CTID>
```

### Tailscale không start

```bash
# Xem logs chi tiết
pct exec <CTID> -- journalctl -u tailscaled -n 100 --no-pager

# Restart
pct exec <CTID> -- systemctl restart tailscaled
```

### Xem log cài đặt

```bash
# Log trên Proxmox host
ls /var/log/tailscale-proxmox/

# Log trong LXC
pct exec <CTID> -- ls /var/log/tailscale-lxc-install*.log
```

---

## ❓ FAQ

**Q: Tại sao luôn tạo LXC mới thay vì cài chung?**

> Cô lập hoàn toàn — nếu có sự cố, chỉ ảnh hưởng đến LXC Tailscale.  
> TUN device và ip_forward chỉ enable trên đúng 1 container.  
> Dễ rebuild mà không ảnh hưởng các service khác.  
> Resource tiêu thụ rất nhỏ: ~64MB RAM, ~300MB disk khi idle.

**Q: Tailscale DERP relay có an toàn không?**

> Traffic vẫn được **mã hóa end-to-end** (WireGuard) — DERP server không đọc được nội dung.  
> Chỉ khác là traffic đi qua server trung gian thay vì kết nối trực tiếp → latency cao hơn.

**Q: Có thể dùng auth key reusable không?**

> Có. Tạo tại [Tailscale Admin → Settings → Keys](https://login.tailscale.com/admin/settings/keys).  
> Khuyến nghị dùng **ephemeral key** cho LXC — tự xóa khỏi tailnet khi offline.

**Q: Unprivileged LXC có bị lỗi TUN không?**

> Script tự động inject TUN device vào config — hoạt động bình thường với Unprivileged LXC trên Proxmox 7+.

**Q: Script có hỗ trợ Alpine Linux không?**

> Hiện tại chỉ hỗ trợ Debian/Ubuntu. Alpine đang được xem xét cho phiên bản sau.

---

## 📄 License

MIT © [dainghiavn](https://github.com/dainghiavn)

---

## 🙏 Credits

- [Tailscale](https://tailscale.com) — WireGuard-based VPN
- [bash-lib](https://github.com/dainghiavn/bash-lib) — Bash helper library
- [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE) — Inspired by script pattern
