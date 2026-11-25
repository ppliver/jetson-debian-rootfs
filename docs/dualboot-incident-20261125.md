# 双系统自动启动事故复盘（2026-11-25）

> AGX Xavier（L4T R35.6.5）双系统自动选择功能：**插 U盘进 Debian、拔 U盘自动回退 eMMC Ubuntu**。
> 本文记录事故全链路（08:52–11:03）、双层根因、UEFI Shell 免刷机救援、以及可复用的教训清单。

---

## 1. 功能实现（事故前的改动）

目标：`extlinux.conf` 保持 `DEFAULT debian`，插拔 U盘无需人工干预。

### 1.1 initrd 补丁 v1 —— 回退逻辑

出厂 initrd（eMMC `/boot/initrd`，约 10MB gzip+cpio）的 `init` 在挂载失败后会走 `process_bash_reboot`（无串口时**无限等待串口回车**，设备彻底静默）。补丁在其后插入回退：

```sh
# mount 失败检查处（原逻辑前面插入）：
if ! mountpoint /mnt/ ; then
    echo "WARN: rootfs ${rootdev} not found, falling back to eMMC rootfs" > /dev/kmsg;
    umount /mnt/ 2>/dev/null;
    rootdev="/dev/mmcblk0p1";       # 改挂 eMMC Ubuntu
    mount ${rootdev} /mnt/;
fi;
mountpoint /mnt/;                    # 原：失败仍走 process_bash_reboot
```

关键安全措施（当时做了，事后证明救命）：

- 保留工厂副本 `/boot/initrd.orig`（md5 与原版一致）
- `primary` / `backup` 菜单项改用**工厂 initrd**（独立兜底路径）
- 新增 `recovery` 菜单项（工厂 initrd + U盘 Debian root）
- `TIMEOUT 100`（10 秒菜单窗口）

### 1.2 initrd 补丁 v2 —— 重试窗口扩容

出厂 init 的挂载重试：**50 次 × 0.2s = 10 秒**。冷启动 U盘 USB 枚举可能慢于 10 秒 → 扩到 **150 次 × 0.2s = 30 秒**。

### 1.3 最终菜单布局

| 菜单项 | initrd | root= | 用途 |
|---|---|---|---|
| debian（DEFAULT） | 补丁版 | UUID=U盘 | 日常主系统 |
| primary | initrd.orig（工厂） | /dev/mmcblk0p1 | eMMC Ubuntu 兜底 |
| backup | initrd.orig（工厂） | /dev/mmcblk0p1 | 同上（无 C4 DTB） |
| recovery | initrd.orig（工厂） | UUID=U盘 | U盘在位时的人工救援入口 |

---

## 2. 事故时间线

| 时间 | 事件 |
|---|---|
| 08:52 | 打完 v1 补丁后带 U盘 sysrq 重启 → SSH 不通、ARP 不应答 |
| 09:0x | 反复断电上电（**每失败一次都在扣减 A/B 重试计数**）→ 全部静默 |
| 09:05 | ping 偶通（后确认是路由器假应答；本链路唯一可靠判活信号 = SSH 22 端口） |
| ~09:3x | 接显示器：UEFI 画面后**无 L4TLauncher 菜单**，直接 `L4TLauncher: Attempting Recovery Boot` |
| 09:4x | UEFI Shell 尝试恢复 initrd：**ext4 全部只读**（copy/edit 保存均失败）→ 放走 UEFI 层改文件 |
| ~10:3x | 源码分析（edk2-nvidia `L4TLauncher.c` / `L4TRootfsValidation.c`）定位 A/B 锁定机制 |
| ~10:4x | UEFI Shell `dmpstore -d` 删除 `RootfsStatusSlotA/B` → `reset` |
| ~10:45 | 菜单恢复，自动超时进 Debian 成功（**证明补丁 initrd 本身工作正常**） |
| 10:52 | v2 补丁（30s 重试窗口）落盘 |
| 10:54 | 拔 U盘实测：屏幕刷 "can't find uuid" 30 秒 → **静默自动回退进 eMMC Ubuntu**，SSH 通，cuInit=0 |
| 11:00 | 插回 U盘实测：直接进 Debian，零额外等待，cuInit=0 |
| 11:02 | 修复 U盘 Debian 侧 ntp.conf（debian pool 国内不通 → aliyun/腾讯），A/B 变量确认自愈重建 |

---

## 3. 双层根因

### 根因 1：出厂 initrd 挂载重试窗口太短（10s）

冷启动时 U盘 USB 枚举 + ext4 探测可能超过 10 秒 → mount 失败 → `process_bash_reboot` → 无串口 → 设备静默（不是 panic，是**等人按串口回车**）。首次重启就是踩的这个。

### 根因 2：连续失败扣减 A/B rootfs 重试计数 → 固件锁定 Recovery Boot

NVIDIA 防变砖机制（`L4TRootfsValidation.c`）：每次启动 L4TLauncher 都会递减槽位重试计数；扣到 0 后 `RootfsStatusSlotA` 被标为 unbootable → 固件**跳过 extlinux 菜单直接 "Attempting Recovery Boot"**，而 Recovery 路径加载的还是坏 initrd → 继续失败。

**症状特征**（记住这个，别再走弯路）：
- `Attempting Recovery Boot` 出现 = **不是 extlinux.conf 解析问题**，是 rootfs 状态变量问题
- 菜单完全不显示（不是超时进了默认项）
- `dmpstore` 读 `L4TDefaultBootMode` = `01 00 00 00`（DIRECT，正常值）也可佐证

---

## 4. 救援流程（免刷机，UEFI Shell）

### 4.1 进入 Shell

F11 → 启动介质界面 / 或 UEFI 菜单选 UEFI Shell。

### 4.2 关键事实

- **UEFI Shell 下所有 ext4 分区（eMMC/U盘）只读**——R35 的 UEFI ext4 驱动不支持写；只有 FAT32 可写
- 变量 GUID：`781E084C-A330-417C-B678-38E696380CB9`（NVIDIAPublicVariableGuid）

### 4.3 删除 rootfs 状态变量（解锁菜单）

```
dmpstore -d -guid 781E084C-A330-417C-B678-38E696380CB9 RootfsStatusSlotA
dmpstore -d -guid 781E084C-A330-417C-B678-38E696380CB9 RootfsStatusSlotB
```

- `RootfsRedundancyLevel` 写保护删不掉（无所谓）；`RootfsMaxRetries` 不存在（实际名 `RootfsRetryCountMax`）
- 源码保证：变量读不到 → 校验函数提前返回错误 → 启动模式保持 DIRECT → **菜单恢复**
- `L4TDefaultBootMode=01` 是正常值，**不要删**

### 4.4 重启后

```
reset
```

`Attempting GRUB Boot`（跳过）→ 可能一行 `Failed to validate rootfs status`（好现象）→ extlinux 菜单 → 选 primary。

### 4.5 事后自愈确认

Ubuntu 成功启动后会自动重建 A/B 变量（健康值：`RootfsStatusSlotA = 0`（成功）、`RootfsRetryCountMax = 3`），在 Linux 里验证：

```bash
sudo od -A x -t x1 /sys/firmware/efi/efivars/RootfsStatusSlotA-781e084c-a330-417c-b678-38e696380cb9
# 000000 07 00 00 00 00 00 00 00   ← 前4字节是 EFI 属性，数据 = 0（SUCCESS）
```

---

## 5. 验收矩阵（全部通过）

| 场景 | 结果 |
|---|---|
| U盘在位冷启动 | 直接进 Debian，零额外等待，cuInit=0，网络 OK |
| 拔 U盘冷启动 | 屏幕刷 `can't find uuid`（30s 重试窗口正常现象）→ 静默回退进 eMMC Ubuntu，SSH/cuInit=0 |
| A/B 变量 | Ubuntu 启动后自动重建，SlotA=0、RetryCountMax=3 |

**屏幕现象解读**：回退过程的 WARN 走 `/dev/kmsg` 不上屏，挂 eMMC 成功也无输出 → 屏幕停在最后的 mount 报错看似"卡死"，实际正在继续启动。等 1~2 分钟即可。

---

## 6. 教训清单

1. **改 initrd 必须同时验证"失败路径"**：mount 重试窗口、失败后的去向（本例 `process_bash_reboot` 无串口 = 静默死锁），而不是只验证成功路径。
2. **失败启动会消耗 A/B 重试预算**：调试期反复断电上电要节制；连续 ~3 次失败即触发 Recovery 锁定。锁定后删 `RootfsStatusSlotA/B` 即解。
3. **UEFI 层改不了 ext4**：R35 UEFI ext4 驱动只读。文件级救援要么在 Linux 里做，要么删 UEFI 变量（FAT32 例外可写）。
4. **ping 不是判活信号**：路由器会假应答；用 SSH 22 端口 TCP 探测。
5. **补丁要留独立兜底**：`initrd.orig` + primary/backup 用工厂 initrd 的设计，使任何补丁事故都有不依赖补丁的启动路径。
6. **排查顺序**：先看屏幕走到哪（UEFI→Launcher→菜单→内核），`Attempting Recovery Boot` = 查 rootfs 状态变量；菜单正常但进不了系统 = 查 initrd/rootfs。
7. NTP：无 RTC 电池设备冷启动是假时钟；国内环境用 `ntp.aliyun.com` / `time1.cloud.tencent.com`，debian pool 全不通。

---

## 7. 相关文件

| 文件 | 位置 |
|---|---|
| initrd 补丁脚本 v1（回退） | 仓库 [`tools/dualboot_initrd_v1_fallback.sh`](../tools/dualboot_initrd_v1_fallback.sh) |
| initrd 补丁脚本 v2（重试扩容） | 仓库 [`tools/dualboot_initrd_v2_retry30s.sh`](../tools/dualboot_initrd_v2_retry30s.sh) |
| 补丁后 init / extlinux.conf | 设备 eMMC `/boot/`（`initrd.orig` = 工厂副本） |
| L4TLauncher 源码（模式决策/Rootfs 校验） | github.com/NVIDIA/edk2-nvidia `Silicon/NVIDIA/Application/L4TLauncher/` |

## 8. 事故后的工具化成果：`dualboot` 切换命令

事故处理过程中验证的所有机制，最终收敛为一个日常运维工具 [`tools/dualboot`](../tools/dualboot)，部署在**两套系统**（USB Debian + eMMC Ubuntu）的 `/usr/local/bin/dualboot`：

```
sudo dualboot status          # 当前系统 / 菜单项 / 下次启动目标
sudo dualboot poweroff        # 关机
sudo dualboot reboot          # 重启（按当前 DEFAULT）
sudo dualboot switch debian   # 下次启动进 USB Debian（3 秒后自动重启）
sudo dualboot switch ubuntu   # 下次启动进 eMMC Ubuntu
sudo dualboot switch <label> [--noreboot]   # primary / backup / recovery
```

设计要点：

- **只改规范 extlinux.conf 的 `DEFAULT` 行**——initrd 补丁与拔盘回退逻辑完全不动，A/B 状态变量不受影响（不会重演 §3 根因 2 的锁定）
- 自动定位配置：eMMC Ubuntu 下直接改自己的 `/boot`（root 即 mmcblk0p1）；Debian 下临时挂载 eMMC APP 分区（`/mnt/.dualboot-emmc`）改完即卸
- 关机/重启走 `systemctl --no-wall`，精简 rootfs 缺 reboot 二进制时兜底 sysrq
- 校验：非法 label 拒绝（exit 2）、无 sudo 报 mount 错误、切换往返后 DEFAULT 正确落盘

已实测（2026-11-25）：Debian 侧 status/switch 往返/错误处理全通过；Ubuntu 侧为同代码路径，待首次切换时顺手确认。
