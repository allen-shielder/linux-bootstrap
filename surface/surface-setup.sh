#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# Surface Debian One-shot Setup
# 1) 当前用户加入 sudo（获得 root 权限）
# 2) 安装 linux-surface 专用内核
# 3) 安装 Surface 硬件驱动包
# 4) 电池 & 充电优化
# 5) 内存优化
# 6) 触控优化
# 7) 功耗优化工具
# 8) 安装 surface-doctor，并提供 `surface doctor` 命令
# ==========================================================

if [[ "${EUID}" -ne 0 ]]; then
  echo "❌ 请用 sudo 运行：sudo $0"
  exit 1
fi

USER_NAME="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
if [[ -z "${USER_NAME}" || "${USER_NAME}" == "root" ]]; then
  echo "❌ 无法识别当前普通用户（SUDO_USER/logname 为空）。请用 sudo 从普通用户运行本脚本。"
  exit 1
fi

ok()   { echo -e "✅ $*"; }
warn() { echo -e "⚠️  $*"; }
bad()  { echo -e "❌ $*"; }
info() { echo -e "ℹ️  $*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

echo "=============================================="
echo " Surface Setup for Debian"
echo " User: ${USER_NAME}"
echo " Host: $(hostname) | Kernel: $(uname -r)"
echo " Time: $(date)"
echo "=============================================="
echo

# ----------------------------
# 1) 将当前用户加入“root权限”（正确做法：加入 sudo 组）
# ----------------------------
echo "[1/8] Add user to sudo group (root privilege via sudo)"
apt-get update -y
apt-get install -y sudo
if id -nG "${USER_NAME}" | grep -qw sudo; then
  ok "${USER_NAME} 已在 sudo 组"
else
  usermod -aG sudo "${USER_NAME}"
  ok "已将 ${USER_NAME} 加入 sudo 组（重新登录后生效）"
fi
echo

# ----------------------------
# 2) 添加 linux-surface 仓库并安装 Surface 专用内核
#    repo: https://pkg.surfacelinux.com/debian release main
# ----------------------------
echo "[2/8] Install linux-surface kernel (repo + packages)"
apt-get install -y ca-certificates curl wget gnupg apt-transport-https

install -d -m 0755 /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/linux-surface.gpg ]]; then
  curl -fsSL https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc \
    | gpg --dearmor -o /etc/apt/keyrings/linux-surface.gpg
  chmod 0644 /etc/apt/keyrings/linux-surface.gpg
  ok "已写入 linux-surface GPG key"
else
  ok "linux-surface GPG key 已存在"
fi

cat >/etc/apt/sources.list.d/linux-surface.list <<'EOF'
deb [arch=amd64 signed-by=/etc/apt/keyrings/linux-surface.gpg] https://pkg.surfacelinux.com/debian release main
EOF
ok "已写入 linux-surface APT 源：/etc/apt/sources.list.d/linux-surface.list"

apt-get update -y

# Secure Boot 如果开着，后面可能需要 MOK（可选）
SB_STATE="unknown"
if need_cmd mokutil; then
  if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then SB_STATE="enabled"; else SB_STATE="disabled"; fi
fi
info "Secure Boot: ${SB_STATE}"

# 内核 + 触控核心组件（iptsd）+ wacom
# 注意：包名以 linux-surface 仓库为准；如果某些包缺失，脚本会给出提示
set +e
apt-get install -y linux-image-surface linux-headers-surface iptsd libwacom-surface
RC=$?
set -e
if [[ $RC -eq 0 ]]; then
  ok "linux-surface 内核与关键组件已安装"
else
  warn "linux-surface 包安装过程中出现错误。常见原因：网络/仓库访问问题。你把错误输出贴我我帮你定位。"
fi

# 如果 Secure Boot enabled，尝试安装 MOK 包（存在则装，不存在跳过）
if [[ "${SB_STATE}" == "enabled" ]]; then
  set +e
  apt-get install -y linux-surface-secureboot-mok
  set -e
  info "Secure Boot 开启时，可能需要按提示完成 MOK enroll（重启时的蓝屏菜单）。"
fi

systemctl enable --now iptsd >/dev/null 2>&1 || true
echo

# ----------------------------
# 3) 安装 Surface 硬件驱动包（尽力安装：有些包依型号/仓库版本）
# ----------------------------
echo "[3/8] Install Surface hardware drivers (best-effort)"
# 常用：surface-control / surface-dtx-daemon / libwacom-surface / surface-battery
# 注意：不同版本仓库可能包名略有差异，失败会提示但不中断
DRIVER_PKGS=(surface-control surface-dtx-daemon surface-battery)
for p in "${DRIVER_PKGS[@]}"; do
  if apt-cache show "$p" >/dev/null 2>&1; then
    apt-get install -y "$p"
    ok "已安装：$p"
  else
    warn "仓库里未找到：$p（跳过）"
  fi
done
echo

# ----------------------------
# 4) 电池 & 充电优化
# ----------------------------
echo "[4/8] Battery & charging optimization"
apt-get install -y tlp tlp-rdw fwupd
systemctl enable --now tlp >/dev/null 2>&1 || true
ok "已安装并启用 TLP"

# thermald：Intel 平台建议装（降温/稳频/更合理的功耗）
apt-get install -y thermald || true
systemctl enable --now thermald >/dev/null 2>&1 || true
ok "已安装 thermald（如平台支持）"

info "固件更新（建议之后手动跑一次）：sudo fwupdmgr update"
echo

# ----------------------------
# 5) 内存优化（earlyoom）
# ----------------------------
echo "[5/8] Memory optimization (earlyoom)"
apt-get install -y earlyoom
# 推荐配置：内存低于 10% 开始处理，swap 低于 5% 也处理；优先杀浏览器/IDE等
cat >/etc/default/earlyoom <<'EOF'
# Managed by surface-setup.sh
EARLYOOM_ARGS="-m 10 -s 5 --prefer 'chrome|chromium|code|java|node|python|firefox' --avoid 'sshd|systemd|Xorg|gnome-shell|plasmashell'"
EOF
systemctl enable --now earlyoom >/dev/null 2>&1 || true
ok "earlyoom 已安装并启用"
echo

# ----------------------------
# 6) 触控优化（libinput + 工具 + 可选手势）
# ----------------------------
echo "[6/8] Touch optimization (libinput / tools)"
apt-get install -y xserver-xorg-input-libinput libinput-tools || true

# 可选：X11 手势（Wayland/gnome 通常不靠它）
# 安装不影响系统，能给 KDE/X11 用手势
apt-get install -y touchegg || true
systemctl enable --now touchegg >/dev/null 2>&1 || true

ok "触控基础组件已安装（iptsd + libinput + 可选 touchegg）"
echo

# ----------------------------
# 7) 功耗优化工具（powertop）
# ----------------------------
echo "[7/8] Power optimization tools (powertop auto-tune)"
apt-get install -y powertop

cat >/etc/systemd/system/powertop-autotune.service <<'EOF'
[Unit]
Description=Powertop auto-tune
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/powertop --auto-tune
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now powertop-autotune.service >/dev/null 2>&1 || true
ok "powertop auto-tune 已启用"
echo

# ----------------------------
# 8) 安装 surface-doctor + surface 命令（surface doctor）
# ----------------------------
echo "[8/8] Install surface-doctor and `surface doctor` command"
cat >/usr/local/bin/surface-doctor <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ok()   { echo -e "✅ $*"; }
warn() { echo -e "⚠️  $*"; }
bad()  { echo -e "❌ $*"; }
info() { echo -e "ℹ️  $*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

echo "=============================================="
echo " Surface Doctor"
echo " Host: $(hostname) | Kernel: $(uname -r)"
echo " Time: $(date)"
echo "=============================================="
echo

# [0] Kernel check
echo "[0/6] Surface kernel"
if uname -r | grep -qi surface; then ok "正在使用 linux-surface 内核 ✔"
else warn "当前不是 linux-surface 内核（建议安装 linux-image-surface）"
fi
echo

# [1] Surface drivers
echo "[1/6] Surface driver modules"
surface_mods=(surface_aggregator surface_aggregator_registry surface_acpi_notify surface_platform_profile surface_gpe)
missing=0
for m in "${surface_mods[@]}"; do
  if lsmod | awk '{print $1}' | grep -qx "$m"; then ok "module loaded: $m"
  else bad "module missing: $m"; missing=1
  fi
done
[[ $missing -eq 0 ]] && ok "Surface 驱动 ✔" || warn "Surface 驱动可能不完整"
echo

# [2] IPTS / Touch daemon
echo "[2/6] Touch (IPTS)"
if systemctl is-enabled iptsd >/dev/null 2>&1; then ok "iptsd enabled ✔"; else warn "iptsd not enabled"; fi
if systemctl is-active iptsd >/dev/null 2>&1; then ok "iptsd active ✔"; else warn "iptsd not active（触控异常时重点看这里：journalctl -u iptsd -e）"; fi
echo

# [3] Battery health (upower)
echo "[3/6] Battery health"
if ! need_cmd upower; then
  warn "upower not found. Install: sudo apt install upower"
else
  bat="$(upower -e | grep -m1 -E 'BAT|battery' || true)"
  if [[ -z "$bat" ]]; then
    warn "No battery device found via upower."
  else
    bi="$(upower -i "$bat")"
    cap="$(echo "$bi" | awk -F': ' '/capacity:/ {print $2}' | awk '{print $1}' | head -n1)"
    cyc="$(echo "$bi" | awk -F': ' '/charge-cycles:/ {print $2}' | awk '{print $1}' | head -n1)"
    st="$(echo "$bi" | awk -F': ' '/state:/ {print $2}' | head -n1)"
    pct="$(echo "$bi" | awk -F': ' '/percentage:/ {print $2}' | head -n1)"
    info "state: ${st:-?} | charge: ${pct:-?} | cycles: ${cyc:-n/a} | capacity: ${cap:-?}%"
  fi
fi
echo

# [4] Charging check (power_supply)
echo "[4/6] Charging / AC online"
ac_path=""
for p in /sys/class/power_supply/AC/online /sys/class/power_supply/ADP*/online /sys/class/power_supply/*/online; do
  [[ -r "$p" ]] || continue
  base="$(basename "$(dirname "$p")")"
  if [[ "$base" == "AC" || "$base" == ADP* ]]; then ac_path="$p"; break; fi
done

if [[ -n "$ac_path" ]]; then
  val="$(cat "$ac_path" 2>/dev/null || echo unknown)"
  if [[ "$val" == "1" ]]; then ok "系统识别已插电 ✔"
  elif [[ "$val" == "0" ]]; then warn "系统认为未插电（若实际已插：可能 EC 抖动/识别延迟）"
  else warn "AC online 状态未知：$val"
  fi
else
  warn "未找到 AC online 路径（设备命名可能不同）"
fi

echo
echo "Battery power_supply (BAT*) details:"
for b in /sys/class/power_supply/BAT*; do
  [[ -d "$b" ]] || continue
  name="$(basename "$b")"
  echo "  [$name]"
  for f in status present capacity energy_now energy_full energy_full_design power_now current_now voltage_now; do
    [[ -r "$b/$f" ]] && printf "    %-18s %s\n" "$f:" "$(cat "$b/$f")"
  done
done
echo

# [5] Power tools quick check
echo "[5/6] Power tools"
systemctl is-active tlp >/dev/null 2>&1 && ok "TLP active ✔" || warn "TLP not active"
systemctl is-active earlyoom >/dev/null 2>&1 && ok "earlyoom active ✔" || warn "earlyoom not active"
systemctl is-enabled powertop-autotune.service >/dev/null 2>&1 && ok "powertop auto-tune enabled ✔" || warn "powertop auto-tune not enabled"
echo

echo "=============================================="
echo " Done.  (run: surface doctor)"
echo "=============================================="
EOF
chmod +x /usr/local/bin/surface-doctor
ok "已安装 /usr/local/bin/surface-doctor"

cat >/usr/local/bin/surface <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
shift || true

case "$cmd" in
  doctor) exec /usr/local/bin/surface-doctor "$@" ;;
  *) echo "Usage: surface doctor"; exit 2 ;;
esac
EOF
chmod +x /usr/local/bin/surface
ok "已安装 /usr/local/bin/surface（支持：surface doctor）"
echo

echo "=============================================="
ok "全部步骤完成"
info "重要：请重新登录一次让 sudo 组生效；并建议重启切换到 surface 内核。"
info "重启后验证：uname -r | grep -i surface && surface doctor"
echo "=============================================="
