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
# [ADD] Debian non-free-firmware + Intel firmware (GPU/Wi-Fi) + microcode
# ----------------------------
echo "[2.5/8] Firmware & microcode (Intel iGPU / Wi-Fi)"

# Detect Debian codename (bookworm/trixie/etc.)
source /etc/os-release || true
CODENAME="${VERSION_CODENAME:-}"

# Ensure non-free-firmware component enabled (Debian 12+)
# We try to append missing components to existing "deb ... main" lines.
if [[ -n "${CODENAME}" && -f /etc/apt/sources.list ]]; then
  cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%F-%H%M%S)" || true

  # Add contrib/non-free/non-free-firmware if missing on each deb line
  sed -i -E \
    's/^(deb\s+[^#\n]+\s+'"${CODENAME}"'\s+main)(\s*)$/\1 contrib non-free non-free-firmware\2/;
     s/^(deb\s+[^#\n]+\s+'"${CODENAME}"'-updates\s+main)(\s*)$/\1 contrib non-free non-free-firmware\2/;
     s/^(deb\s+[^#\n]+\s+'"${CODENAME}"'-security\s+main)(\s*)$/\1 contrib non-free non-free-firmware\2/' \
    /etc/apt/sources.list || true

  ok "已尝试在 /etc/apt/sources.list 启用 contrib/non-free/non-free-firmware"
else
  warn "未检测到 VERSION_CODENAME 或 /etc/apt/sources.list 不存在，跳过自动启用 non-free-firmware"
fi

apt-get update -y

# Install CPU microcode + common firmware bundles
apt-get install -y intel-microcode firmware-linux firmware-misc-nonfree || true

# Optional: install Intel Wi-Fi firmware if available
if apt-cache show firmware-iwlwifi >/dev/null 2>&1; then
  apt-get install -y firmware-iwlwifi || true
  ok "已安装 firmware-iwlwifi（Intel Wi-Fi）"
fi

ok "固件/微码安装完成（建议重启生效）"
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
# [NEW] Suspend / Resume stability fixes (Surface "sleep of death")
# ----------------------------
echo "[7.5/8] Suspend/Resume fix (prevent sleep-of-death)"

# 0) Ensure tools exist
apt-get install -y upower pciutils || true

# 1) Prefer s2idle over deep (often more stable on Surface)
#    We set kernel param: mem_sleep_default=s2idle
#    NOTE: takes effect after update-grub + reboot
if [[ -f /etc/default/grub ]]; then
  if grep -q 'mem_sleep_default=' /etc/default/grub; then
    # already set - leave it
    ok "GRUB 已包含 mem_sleep_default 参数（跳过）"
  else
    # append to GRUB_CMDLINE_LINUX_DEFAULT
    sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 mem_sleep_default=s2idle"/' /etc/default/grub || true
    ok "已设置 mem_sleep_default=s2idle（重启后生效）"
  fi
  update-grub || true
else
  warn "/etc/default/grub 不存在（可能不是 GRUB 引导），跳过 mem_sleep_default 设置"
fi

# 2) Disable USB autosuspend in TLP (common cause of resume issues)
#    This is conservative: higher power use, but usually more stable.
if [[ -f /etc/default/tlp ]]; then
  if grep -q '^USB_AUTOSUSPEND=' /etc/default/tlp; then
    sed -i 's/^USB_AUTOSUSPEND=.*/USB_AUTOSUSPEND=0/' /etc/default/tlp
  else
    echo 'USB_AUTOSUSPEND=0' >> /etc/default/tlp
  fi
  systemctl restart tlp >/dev/null 2>&1 || true
  ok "已设置 TLP: USB_AUTOSUSPEND=0"
else
  warn "/etc/default/tlp 不存在（TLP 可能没安装/路径不同）"
fi

# 3) i915 resume fix hook (rebind Intel GPU after resume) + logging
#    Helps on some Surfaces with black screen / stuck GPU after wake.
cat >/usr/local/bin/surface-sleep-fix <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"

log() { logger -t surface-sleep-fix "$*"; }

rebind_i915() {
  local dev
  dev="$(lspci -Dn | awk '$0 ~ /VGA compatible controller/ && $0 ~ /8086/ {print $1; exit}')"
  [[ -z "${dev:-}" ]] && { log "no Intel VGA device found"; return 0; }
  # Convert 00:02.0 -> 0000:00:02.0
  dev="0000:${dev}"
  local path="/sys/bus/pci/devices/${dev}"
  [[ -d "$path" ]] || { log "PCI path not found: $path"; return 0; }

  if [[ -w "${path}/driver/unbind" && -w /sys/bus/pci/drivers/i915/bind ]]; then
    echo "$dev" > "${path}/driver/unbind" || true
    sleep 1
    echo "$dev" > /sys/bus/pci/drivers/i915/bind || true
    log "rebound i915 for ${dev}"
  else
    log "i915 bind/unbind not available"
  fi
}

case "$ACTION" in
  pre)
    # before sleep
    log "pre-sleep: mem_sleep=$(cat /sys/power/mem_sleep 2>/dev/null || echo '?')"
    ;;
  post)
    # after resume
    log "post-resume: running i915 rebind"
    rebind_i915
    ;;
  *)
    echo "Usage: $0 pre|post" >&2
    exit 2
    ;;
esac
EOF
chmod +x /usr/local/bin/surface-sleep-fix
ok "已安装 /usr/local/bin/surface-sleep-fix"

# 4) systemd sleep hook
install -d /lib/systemd/system-sleep
cat >/lib/systemd/system-sleep/surface-sleep-fix <<'EOF'
#!/usr/bin/env bash
# systemd calls: <script> pre|post <sleep-type>
case "$1" in
  pre)  /usr/local/bin/surface-sleep-fix pre  || true ;;
  post) /usr/local/bin/surface-sleep-fix post || true ;;
esac
exit 0
EOF
chmod +x /lib/systemd/system-sleep/surface-sleep-fix
ok "已安装 systemd sleep hook: /lib/systemd/system-sleep/surface-sleep-fix"

echo
info "Suspend 修复已添加。建议重启后测试：systemctl suspend"
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

echo "[?/?] Sleep mode"
if [[ -r /sys/power/mem_sleep ]]; then
  info "mem_sleep options: $(cat /sys/power/mem_sleep)"
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
