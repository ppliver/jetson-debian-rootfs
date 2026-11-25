# jetson-debian-rootfs（中文版）

**Jetson AGX Xavier**（L4T R35.6.5 / JetPack 5.1.x）专用 Debian 11 (bullseye) rootfs，在 GitHub Actions **arm64** 原生 runner 上构建（公开仓库免费、无 qemu 模拟，与设备 native 构建完全同构）。

产物是可直接跑 CUDA 的 rootfs：`cuInit=0`，Xavier 30991MB / CC 7.2 / 8 SM（2026-11-24 已在真机用同一配方验证）。

> 英文版：[README.md](README.md) ｜ 事故复盘：[docs/dualboot-incident-20261125.md](docs/dualboot-incident-20261125.md)

## 内容构成

| 层 | 来源 |
|---|---|
| Debian 11 bullseye 基础 | debootstrap（镜像自动回退：deb.debian.org → TUNA → archive） |
| NVIDIA L4T 用户态（libcuda/固件/内核模块/DTB） | `repo.download.nvidia.com/jetson/{common,t194}`，suite `r35.6`，锁版 `35.6.5-20260701022834`（与运行内核 `5.10.216-tegra` 精确同版） |
| 现场验证过的补丁层 | modules-load.d/nv.conf + 幂等 `nvgpu-autoload.service`、tegra ldconfig 路径、MAC 绑定 udev `ethlan` + 静态 IP、DNS 钩子、NTP aliyun + Asia/Shanghai、fstab（根分区 sync + NVMe nofail）、sudo NOPASSWD、串口 ttyTCU0 |

无头定位：刻意排除 GUI/Weston/X11/GStreamer/摄像头 deb。已含：systemd、ssh、sudo、gcc、make、kmod、ntp、python3、rsync。

## CI 构建

推送 `main` 且改动 `build/**` 自动触发，或手动 workflow_dispatch。产物 artifact：`debian11-xavier-rootfs`（约 3GB tar.zst + sha256 + build_info.txt），保留 14 天。

## 构建产物 vs 双系统引导层（分工说明）

- **本仓库 CI 构建 = rootfs 内容层**：U盘/TF 卡里的 Debian 操作系统（含 NVIDIA 组件与补丁）。
- **双系统自动选择 = eMMC 引导层**：`/boot/initrd` 补丁（挂载重试 30s + 拔盘回退）和 `/boot/extlinux/extlinux.conf` 菜单，位于 eMMC，与 rootfs 独立。
- 两者交集：rootfs 换介质（U盘↔TF 卡）只需改 extlinux.conf 里的 `root=UUID=...`，引导层补丁不用动（回退逻辑按 UUID 找设备，对介质无感）。
- 引导层补丁脚本已收录本仓库：[`tools/`](tools/)（v1 回退 + v2 重试扩容，真机验证通过）。

## 刷写到启动盘（在 Xavier 上执行）

### U盘（/dev/sdX，如 /dev/sda1）

```bash
lsblk                          # 确认盘符，别刷错盘！
sudo mkfs.ext4 -L rootfs /dev/sdX1
sudo blkid /dev/sdX1           # 记下 UUID=...
sudo mount /dev/sdX1 /mnt/usb
sudo tar -I zstd -xf debian11-*.rootfs.tar.zst -C /mnt/usb
sync
```

### TF 卡（板载卡槽，/dev/mmcblk1p1）

AGX Xavier 载板自带 TF 卡槽，内核识别为 **mmcblk1**（与 eMMC 的 mmcblk0 区分，不是 /dev/sda）：

```bash
lsblk                          # 应看到 mmcblk1（TF 卡），mmcblk0 是 eMMC
sudo mkfs.ext4 -L rootfs /dev/mmcblk1p1
sudo blkid /dev/mmcblk1p1      # 记下 UUID=...
sudo mount /dev/mmcblk1p1 /mnt/tf
sudo tar -I zstd -xf debian11-*.rootfs.tar.zst -C /mnt/tf
sync
```

**TF 卡 vs U盘 选型提示**：

| 项 | TF 卡 | U盘 |
|---|---|---|
| 设备名 | /dev/mmcblk1p1 | /dev/sdX1 |
| 冷启动枚举速度 | 快（总线直连，秒级） | 可能慢 10s+（initrd 补丁已扩到 30s 重试窗口兜底） |
| 性能 | 受卡本身限制（低端卡写只有 MB 级） | 通常更快 |
| 可靠性 | 有假卡风险（本项目实测一张 16G 卡报废：能读不能写、md5 比对失败，软件无法修复） | 换卡即换介质 |

⚠️ **在 WSL 里 mkfs 必须加** `-O ^metadata_csum_seed,^orphan_file`（或在设备上直接 mkfs），否则 UEFI 的 ext4 驱动挂载不了 APP/rootfs 分区。

### 启动项指向（eMMC /boot/extlinux/extlinux.conf）

```bash
# debian 菜单项的 APPEND 行改成对应介质 UUID（U盘/TF 卡通用）
root=UUID=<你的rootfs-UUID>
```

### 双系统自动选择（引导层补丁，一次性操作）

在能写 eMMC 的系统里执行（详见 [tools/](tools/) 内注释）：

```bash
sudo bash tools/dualboot_initrd_v1_fallback.sh    # 回退补丁 + initrd.orig 工厂副本 + 菜单四项
sudo bash tools/dualboot_initrd_v2_retry30s.sh    # 挂载重试 10s→30s
```

效果：**插启动盘直接进 Debian（零额外等待）；拔掉启动盘，30 秒重试后自动进 eMMC Ubuntu**。

菜单布局：

| 菜单项 | initrd | root= | 用途 |
|---|---|---|---|
| debian（DEFAULT） | 补丁版 | UUID=启动盘 | 日常主系统 |
| primary | initrd.orig（工厂） | /dev/mmcblk0p1 | eMMC Ubuntu 兜底 |
| backup | initrd.orig（工厂） | /dev/mmcblk0p1 | 同上（无 C4 DTB） |
| recovery | initrd.orig（工厂） | UUID=启动盘 | 启动盘在位时的人工救援入口 |

## 凭据与网络默认值（可在 build_rootfs.sh 中用环境变量覆盖）

- 主机名 `debian11-xavier`，板载网卡 MAC `48:B0:2D:3D:CB:A8` → `ethlan` → 192.168.219.171/24 gw 192.168.219.176

## 踩坑记录（已固化进本仓库）

- `rmmod nvgpu` 必内核 panic；改用幂等加载（modprobe）。
- 强制重启会丢未 sync 的 ext4 写入 → 根分区挂载 `sync`。
- Xavier 无 RTC 电池 → 每次冷启动是假时钟；预装 NTP（aliyun）+ Asia/Shanghai。
- `/dev/nvhost-gpu` 可能不在 `ls /dev` 里，别用节点存在性判断 GPU 失败；以 `cuInit` 为准。
- debootstrap 必须 `--no-merged-usr`：merged-usr 下注入 NVIDIA kernel deb 会把 `/lib` 符号链接替换成真目录，杀掉 ELF 加载器（详见 git 历史与脚本注释）。
- 打包前必须 umount proc/dev/sys，否则 tar 会读 `/proc/kcore` 挂死。
- **双系统引导层事故**（A/B rootfs 重试计数锁定 → Recovery Boot 无菜单）：救援命令与完整复盘见 [docs/dualboot-incident-20261125.md](docs/dualboot-incident-20261125.md)。
  快速救援（UEFI Shell）：
  ```
  dmpstore -d -guid 781E084C-A330-417C-B678-38E696380CB9 RootfsStatusSlotA
  dmpstore -d -guid 781E084C-A330-417C-B678-38E696380CB9 RootfsStatusSlotB
  reset
  ```

## `dualboot` —— 双系统切换命令（两套系统均已安装）

已部署到 U盘 Debian 与 eMMC Ubuntu 的 `/usr/local/bin/dualboot`，用 sudo 调用：

```
dualboot status                # 当前系统 / 菜单项 / 下次启动目标
dualboot poweroff              # 关机
dualboot reboot                # 重启（按当前 DEFAULT）
dualboot switch debian         # 下次启动进 USB Debian（3 秒后自动重启）
dualboot switch ubuntu         # 下次启动进 eMMC Ubuntu
dualboot switch <label> [--noreboot]   # primary / backup / recovery，--noreboot 只改不重启
```

原理：只改规范 extlinux.conf 的 `DEFAULT`（自动定位——Ubuntu 下直接改自己的 /boot；Debian 下临时挂载 eMMC APP 分区改完即卸），initrd 补丁与回退逻辑完全不动。
