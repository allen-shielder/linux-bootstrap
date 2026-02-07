# MATE 桌面给的配置(For Surface)

MATE 默认：

- 不针对触控
    
- 不针对 i915
    
- 不针对 power
    

要手动补。

## 1）开启 compositing（否则卡）

```bash
gsettings set org.mate.Marco.general compositing-manager true
```


## 2）启用 i915 SNA（核显性能关键）

```bash
sudo nano /etc/X11/xorg.conf.d/20-intel.conf
```

写入：

```rust
Section "Device"
   Identifier  "Intel Graphics"
   Driver      "intel"
   Option      "AccelMethod" "sna"
   Option      "TearFree" "true"
EndSection
```

## 3）触控优化（MATE默认很差）

```bash
sudo apt install xserver-xorg-input-libinput
```

然后：

```bash
sudo nano /etc/X11/xorg.conf.d/40-libinput.conf
```

写入：

```rust
Section "InputClass"
    Identifier "libinput touchscreen catchall"
    MatchIsTouchscreen "on"
    Driver "libinput"
    Option "Tapping" "on"
EndSection
```
## 4）MATE 电源策略（Surface关键）

禁用 aggressive power save：

```bash
gsettings set org.mate.power-manager idle-dim-battery false
gsettings set org.mate.power-manager idle-dim-ac false
```
## 5）MATE suspend 修复（必须）

MATE 自己也有 suspend 管理，会和 systemd 打架。

建议：

```bash
sudo apt remove mate-power-manager
```

改用`systemd + tlp` 更稳定。
