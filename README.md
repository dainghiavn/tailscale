# Tailscale Installer

> Cài đặt Tailscale tự động — **tự detect môi trường** và điều chỉnh theo  
> Tích hợp **Preflight Scan** — phân tích mạng, đưa ra khuyến nghị trước khi cài

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Proxmox VE](https://img.shields.io/badge/Proxmox%20VE-7.0%2B-orange)](https://www.proxmox.com)
[![Tailscale](https://img.shields.io/badge/Tailscale-latest-blue)](https://tailscale.com)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%2B-E95420)](https://ubuntu.com)
[![Debian](https://img.shields.io/badge/Debian-11%2B-A81D33)](https://debian.org)

---

## 📋 Mục lục

- [Hỗ trợ môi trường](#-hỗ-trợ-môi-trường)
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

## 🖥️ Hỗ trợ môi trường

Script **tự động detect** môi trường và cài đặt phù hợp — **1 lệnh duy nhất** cho tất cả:

| Môi trường | Detect | Hành động |
|---|---|---|
| **Proxmox VE host** | `pveversion` | Tạo LXC mới → Cài Tailscale bên trong |
| **LXC container** | `/proc/1/environ` | Cài Tailscale trực tiếp vào container |
| **Ubuntu Server** | `OS_ID=ubuntu` | Cài Tailscale trực tiếp |
| **Debian standalone** | `OS_ID=debian` | Cài Tailscale trực tiếp |
| **Raspberry Pi** | `/proc/device-tree/model` | Cài + kiểm tra TUN module |
| **VPS / Cloud** | DMI + cloud-init | Cài + cảnh báo UDP outbound |
| **Docker host** | `docker daemon` | Cài + cảnh báo routing conflict |

### Yêu cầu theo môi trường

| | Proxmox host | Linux standalone |
|---|---|---|
| OS | Proxmox VE 7.0+ | Debian 11+ / Ubuntu 20.04+ |
| RAM | 256MB free | 128MB free |
| Disk | 2GB free (cho LXC) | 512MB free |
| Internet | HTTPS outbound | HTTPS outbound |
| Quyền | root | root |

---

## 🚀 Cài đặt nhanh

**1 lệnh — chạy được mọi nơi:**

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dainghiavn/tailscale/main/ct/tailscale.sh)"
```

Script tự detect môi trường và chạy đúng flow phù hợp.

---

## ✨ Tính năng

### Auto Environment Detection
- Tự nhận biết: **Proxmox host / LXC / Ubuntu / Debian / Raspberry Pi / VPS / Docker**
- Điều chỉnh preflight, menu và flow cài đặt theo từng môi trường
- Cảnh báo đặc thù: Docker routing conflict, RPi TUN module, VPS UDP block

### Preflight Scan thông minh
- Kiểm tra **5 nhóm** trước khi cài: System, Network, UDP/NAT, Tailscale, Security
- Phát hiện **NAT type** — dự đoán chất lượng kết nối P2P
- Đưa ra **khuyến nghị cụ thể** theo tình trạng thực tế
- Cho phép **Re-scan** sau khi kỹ thuật viên tự xử lý network

### Dynamic Menu
- **Chưa cài:** Simple / Advanced
- **Đã cài:** Add-Remove / Update / Re-auth / Uninstall
- Tự ẩn/hiện tùy chọn theo trạng thái hiện tại

### LXC Isolated (Proxmox mode)
- Luôn tạo **LXC mới** — không cài chung với service khác
- Tự động inject **TUN device** vào LXC config
- Hỗ trợ **Unprivileged LXC** (bảo mật tốt hơn)
- Resource tối thiểu: ~64MB RAM, ~300MB disk khi idle

### Chế độ kết nối Tailscale
| Mode | Điều kiện | Latency |
|---|---|---|
| 🟢 Direct P2P | UDP 41641 open + NAT Full/Restricted | < 10ms |
| 🟡 Hybrid | UDP partial / NAT Port-Restricted | Không ổn định |
| 🔴 DERP Only | UDP blocked / Symmetric NAT | 80–200ms |

---

## 🔍 Preflight Scan

Script thực hiện **5 nhóm kiểm tra** và in báo cáo trước khi cài.

### Proxmox mode
```
── ① SYSTEM (Proxmox) ──────────────────────────────
[✓] Proxmox VE 8.2.4         OK
[✓] Disk: 48GB free           OK  (cần 2GB)
[✓] CT ID 200                 OK  (chưa dùng)
[⚠] RAM: 380MB free          WARN (khuyến nghị 512MB+)
[✓] Template debian-12        OK

── ② NETWORK ───────────────────────────────────────
[✓] Gateway: 192.168.1.1     OK
[✓] DNS resolve               OK
[✓] HTTPS controlplane        OK
[ℹ] Hop count: 3 hops        INFO (có firewall trung gian)
[ℹ] External IP: 203.x.x.x  INFO

── ③ UDP / NAT ─────────────────────────────────────
[✗] UDP 41641                 BLOCKED ← firewall chặn
[⚠] NAT type: Symmetric      WARN    ← P2P hạn chế
[✓] TCP 443 DERP fallback     OK

── ④ TAILSCALE ─────────────────────────────────────
[✓] Chưa cài trong LXC nào   Fresh install mode

── ⑤ SECURITY ──────────────────────────────────────
[✓] Unprivileged LXC mode     OK
[ℹ] ip_forward: disabled     INFO (sẽ enable nếu cần)
[ℹ] Proxmox Firewall: ON     INFO (cần thêm rule UDP 41641)
```

### Standalone mode (Ubuntu/Debian/RPi/VPS/Docker)
```
── ① SYSTEM ────────────────────────────────────────
[✓] OS: ubuntu 22.04 jammy    OK
[✓] Architecture: x86_64      OK
[✓] Disk: 12GB free           OK
[✓] systemd: 249              OK
[✓] TUN device: /dev/net/tun  OK

── ② NETWORK / ③ UDP/NAT / ④ TAILSCALE / ⑤ SECURITY
    (tương tự — nhưng không check PVE/storage/CT ID)
```

### Verdict 4 cấp

| Verdict | Điều kiện | Hành động |
|---|---|---|
| 🟢 **GO** | Score tốt, không có lỗi | Tiếp tục ngay |
| 🟡 **WARN** | Có vấn đề nhỏ | Hỏi **C**ontinue / **R**escan / **E**xit |
| 🔴 **STOP** | Vấn đề nghiêm trọng | Phải gõ `FORCE` để bỏ qua |
| ⛔ **ABORT** | Lỗi critical | Tự dừng — không có option tiếp tục |

---

## 📦 Chế độ cài đặt

### Simple Mode
```
✓ Cài Tailscale package
✓ Start tailscaled service
✓ Inject TUN device (Proxmox mode)
✓ Hướng dẫn tailscale up
```

### Advanced Mode
```
✓ Tất cả của Simple
+ Subnet Router  — expose LAN nội bộ vào tailnet
+ Exit Node      — route internet traffic qua máy này
+ Tailscale SSH  — quản lý SSH qua tailnet
+ Auth Key       — authenticate tự động
+ ip_forward     — enable khi cần
+ iptables rules — persist sau reboot
```

### Manage Mode (khi đã cài)
```
[M] Add/Remove features  — toggle Subnet/ExitNode/SSH
[U] Update               — apt upgrade tailscale
[R] Re-authenticate      — khi auth key hết hạn
[X] Uninstall            — gỡ sạch
```

---

## 📁 Cấu trúc repo

```
tailscale/
├── ct/
│   └── tailscale.sh              ← Entry point — chạy mọi môi trường
├── install/
│   └── tailscale-install.sh      ← Install script — chạy trên target machine
├── README.md
└── LICENSE
```

### Dependency
Dùng [bash-lib](https://github.com/dainghiavn/bash-lib) — thư viện helper dùng chung:

```bash
# Tự động import — không cần làm gì thêm
source <(curl -fsSL https://raw.githubusercontent.com/dainghiavn/bash-lib/main/lib.sh)
```

---

## ⚙️ Cách hoạt động

```
bash -c "$(curl ... tailscale.sh)"
│
├─ ct/tailscale.sh
│   ├── Phase 0: detect_environment()
│   │    ├── Proxmox host  → ENV_MODE=proxmox
│   │    ├── LXC container → ENV_MODE=lxc
│   │    └── Linux         → ENV_MODE=standalone
│   │         └── detect OS: ubuntu|debian|raspberrypi|vps|docker
│   │
│   ├── Phase 1: Preflight scan (5 nhóm — theo môi trường)
│   │    ├── Proxmox → check PVE, storage, CT ID, template
│   │    └── Other   → check OS, arch, TUN, disk, RAM
│   │
│   ├── Phase 2: Verdict (GO/WARN/STOP/ABORT) + User confirm
│   │
│   ├── Phase 3: Dynamic menu theo trạng thái
│   │
│   ├── Phase 4: Configure (LXC params nếu Proxmox, Advanced options)
│   │
│   ├── Phase 5: Install theo môi trường
│   │    ├── Proxmox    → tạo LXC → inject TUN → pct_exec_script
│   │    └── Standalone → export env vars → bash install script trực tiếp
│   │
│   └── Phase 6: Summary + auth instructions
│
└─ install/tailscale-install.sh (chạy trên target — LXC hoặc máy hiện tại)
    ├── Step 0: Verify environment (OS, TUN, internet)
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

### Auth thủ công

**Proxmox mode** — vào LXC:
```bash
pct exec <CTID> -- bash
tailscale up
# Mở link hiện ra trên browser
```

**Standalone mode** — chạy trực tiếp:
```bash
tailscale up
# Mở link hiện ra trên browser
```

**Advanced mode** — với đầy đủ tùy chọn:
```bash
tailscale up \
  --advertise-routes=192.168.1.0/24 \
  --advertise-exit-node \
  --ssh \
  --accept-routes
```

### Approve trên Admin Console (Advanced mode)

Vào [Tailscale Admin](https://login.tailscale.com/admin/machines):
```
Subnet Router → Click "..." → Approve subnet routes
Exit Node     → Click "..." → Approve as exit node
```

### Kiểm tra kết nối

```bash
# Proxmox mode
pct exec <CTID> -- tailscale status
pct exec <CTID> -- tailscale netcheck

# Standalone mode
tailscale status
tailscale netcheck
tailscale debug report
```

---

## 🛠️ Quản lý sau cài đặt

Chạy lại script — tự detect đã cài và hiển thị menu quản lý:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dainghiavn/tailscale/main/ct/tailscale.sh)"
```

---

## 🔧 Gỡ lỗi

### TUN device không có

```bash
# Standalone / LXC — thử load module
modprobe tun
echo 'tun' >> /etc/modules

# Proxmox — inject vào LXC config
echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> /etc/pve/lxc/<CTID>.conf
echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" \
  >> /etc/pve/lxc/<CTID>.conf
pct restart <CTID>
```

### UDP 41641 bị chặn

```bash
# Test UDP
echo | nc -u -w3 udp.tailscale.com 41641 && echo OPEN || echo BLOCKED

# Fix Proxmox Firewall
# Datacenter → Firewall → Add:
# Direction: out, Protocol: udp, Dest port: 41641, Action: ACCEPT
```

### Docker host — routing conflict

```bash
# Xem hướng dẫn chính thức
# https://tailscale.com/kb/1130/docker

# Disable Docker iptables nếu dùng Tailscale subnet
# dockerd --iptables=false
```

### Raspberry Pi — TUN không load

```bash
# Load TUN module
modprobe tun
lsmod | grep tun

# Persist sau reboot
echo 'tun' >> /etc/modules-load.d/tun.conf
```

### Xem log cài đặt

```bash
# Proxmox host
ls /var/log/tailscale-proxmox/

# Standalone / LXC
ls /var/log/tailscale-lxc-install*.log

# Tailscale service log
journalctl -u tailscaled -n 100 --no-pager
```

---

## ❓ FAQ

**Q: Tại sao Proxmox mode luôn tạo LXC mới?**

> Cô lập hoàn toàn — sự cố chỉ ảnh hưởng LXC Tailscale.  
> TUN device và ip_forward chỉ enable trên đúng 1 container.  
> Dễ rebuild không ảnh hưởng service khác.  
> Resource nhỏ: ~64MB RAM, ~300MB disk idle.

**Q: Standalone mode có khác gì LXC mode không?**

> Standalone cài trực tiếp lên máy hiện tại (Ubuntu/Debian/RPi/VPS).  
> LXC mode cũng cài trực tiếp nhưng có thêm check TUN từ Proxmox host.  
> Cả 2 đều dùng cùng `install/tailscale-install.sh`.

**Q: Raspberry Pi có cần config thêm không?**

> Script tự detect RPi và kiểm tra TUN module.  
> Nếu thiếu: tự chạy `modprobe tun` và hướng dẫn persist.  
> Hỗ trợ cả armv7l (RPi 3/4 32-bit) và aarch64 (RPi 4/5 64-bit).

**Q: VPS/Cloud có vấn đề gì đặc thù không?**

> Một số provider block UDP outbound → Tailscale sẽ dùng DERP relay.  
> Script cảnh báo rõ ràng nếu detect VPS và UDP bị block.  
> Vẫn hoạt động được qua TCP 443 (DERP) dù latency cao hơn.

**Q: Docker host có dùng được không?**

> Được, nhưng cần cẩn thận với iptables và routing.  
> Script cảnh báo potential conflict với Docker networking.  
> Xem: [tailscale.com/kb/1130/docker](https://tailscale.com/kb/1130/docker)

**Q: Tailscale DERP relay có an toàn không?**

> Traffic vẫn **mã hóa end-to-end** (WireGuard) — DERP không đọc được nội dung.  
> Chỉ khác: đi qua relay thay vì kết nối trực tiếp → latency cao hơn.

**Q: Auth key loại nào nên dùng?**

> Dùng **ephemeral key** cho LXC/server — tự xóa khỏi tailnet khi offline.  
> Tạo tại [Tailscale Admin → Settings → Keys](https://login.tailscale.com/admin/settings/keys).

---

## 📄 License

MIT © [dainghiavn](https://github.com/dainghiavn)

---

## 🙏 Credits

- [Tailscale](https://tailscale.com) — WireGuard-based mesh VPN
- [bash-lib](https://github.com/dainghiavn/bash-lib) — Bash helper library
- [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE) — Inspired by script pattern
