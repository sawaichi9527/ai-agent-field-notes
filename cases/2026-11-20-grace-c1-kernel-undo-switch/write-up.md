# Grace C1 換核心：GRUB_DEFAULT 是「指針」不是「版本」——1043 → 1067，回滾保留

> 2026-11-20 · NVIDIA Grace C1（peer-a，72-core Arm Neoverse V2）· Ubuntu `nvidia-64k` flavor
> · 核心 lineage `6.8.0-XXXX-nvidia-64k`、從 `6.8.0-1043-nvidia-64k` 切到 `6.8.0-1067-nvidia-64k`
> · 需求：**切成 1067，但保留隨時回 1043 的能力，且普通 `apt autoremove` 不能吃掉回滾套件**

## 1. 需求不是「換核心」，而是「換、而且能回來」

這台 Grace C1（peer-a）跑 Ubuntu 的 `nvidia-64k` flavor：核心套件名帶版本、
按 lineage 并存（1043 / 1067 …）。真正的要求是兩件事一起成立：

1. **`6.8.0-1067-nvidia-64k` 成為開機預設**（同一 lineage 裡最新、NVIDIA 驗證的核心）；
2. **回 1043 的路永遠在**，而且**不被普通使用者跑 `apt autoremove` 時自動刪掉**。

這個 case 的價值不是「改一行 grub」——是為什麼「兩條直觉都錯」：

| 直觉 | 真相 |
|---|---|
| 「新安裝的核心就是開機那個」 | 錯。開機由 `GRUB_DEFAULT` 決定，它是 **menuentry 的字串**，不是版本。`needrestart` 把最新核心標成 "expected"、GRUB 上層 'Ubuntu' 入口也跟著最新安裝自動走——**兩者都是噪音**，與指針無關 |
| 「回滾核心就跟其他已裝核心一樣放着，不會消失」 | 錯。这台機器上 **1055→1064 六個中間核心已經全部變成 `rc`（autoremove 已吃掉過）**。不再被指針指向的核心，正是 apt autoremove 想清理的形狀 |

## 2. 先理解「開機預設」是什麼：一個指向 submenu entry 的字串

`GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-1067-nvidia-64k"`：

- `Advanced options for Ubuntu>` 是**子菜单**，GRUB 会把**每一个已安装的核心**都保留一个
  entry（`update-grub` 重生成 grub.cfg，但不删除已安装核心的 submenu entry）。
- 逗號後的字串選**其中一個**。改預設 = 換這個字串，不重裝、不下載。
- 驗證（重開機后）：

```
$ uname -r
6.8.0-1067-nvidia-64k
$ cat /proc/cmdline
BOOT_IMAGE=/vmlinuz-6.8.0-1067-nvidia-64k …
$ getconf PAGE_SIZE
65536
```

回滾同樣是一行字：`GRUB_DEFAULT="…>Ubuntu, with Linux 6.8.0-1043-nvidia-64k"`，grub.cfg 裡
1043 的 entry（含 recovery）仍在（證據 [`grub-pointer-and-entries.txt`](evidence/grub-pointer-and-entries.txt)）。

## 3. 回滾套件的防刪：`apt-mark manual`

`apt autoremove` 刪的是「被它認定為不再被需要的依赖包」。fallback 核心正好是這個形狀：
新的預設不再指向它 → apt 認為「没人用」→ 删掉。保護是把它標成 **manual**（使用者明確安装）：

```
apt-mark manual linux-image-6.8.0-1043-nvidia-64k linux-modules-6.8.0-1043-nvidia-64k \
  linux-modules-nvidia-fs-6.8.0-1043-nvidia-64k linux-tools-6.8.0-1043-nvidia-64k \
  linux-headers-6.8.0-1043-nvidia-64k linux-nvidia-headers-6.8.0-1043 linux-nvidia-tools-6.8.0-1043
```

驗證（`apt-mark showmanual`）：這 7 個 1043 lineage 套件都在 manual list
（證據 [`aptmark-manual.txt`](evidence/aptmark-manual.txt)）。
此时 `autoremove` 不會把它们當 unused-dependency 清除；1067（現役）保持 auto。

## 4. 換心 + 回滾都能「由工具本身」驗證

不要相信「改了 grub 應該沒問題」——用核心/系統自己回答：

| 驗證 | 錄到證據 |
|---|---|
| 現役核心與 boot image | `uname -r` + `/proc/cmdline`（[`post-switch-boot-verify.txt`](evidence/post-switch-boot-verify.txt)） |
| 頁面尺寸（Grace 必須 64K） | `getconf PAGE_SIZE` → 65536 |
| grub 指針 + 存活 entry | grub.cfg `set default` + menuentry 列表（1043 仍在） |
| 回滾套件不被 autoremove | `apt-mark showmanual` |
| 換心有沒有引入新風險 | boot 日志对比（boot 0 = 1067 vs boot -1 = 1043） |

## 5. boot log 对比：換心不引入新風險

`journalctl -b 0` vs `-b -1`，kernel warn/err/fail 计数：**兩者都是 4**，完全相同；
`systemctl --failed` = 0。逐行看 boot 0 的四類已知行，全部在 1043 开机时已存在：

- `CPU features: detected: Broken broadcast TLBI completion` —— arm64 errata **被套用**（好的信号）；
- `tegra-i2c NVDA0301:00/01 cannot use DMA: -19 → falling back to PIO` —— SOC i2c 无 DMA，
  每次都走 PIO，不是新问题；
- kernel watchdog `Delayed init of the lockup detector failed: -19 / Hard watchdog permanently
  disabled` —— kernel 側 watchdog 自我初始化失敗（預載），平台仍有 ACPI SBSA Generic
  Watchdog（boot log 同一段：`found 1 SBSA generic Watchdog(s)`）供系統級 watchdog timeout。

結論：1067 开机 4 条已已知且与 1043 一模一样，**切换没有新增 kernel 側风险**
（證據 [`boot-log-comparison.txt`](evidence/boot-log-comparison.txt)）。

## 6. 讓「為什麼 apt 預期 7.0.0-43-generic」自己回答

这台机器上 `linux-image-7.0.0-43-generic`（generic / 4K）也 installed，GRUB 也提供它、`needrestart`
也把它標 "expected"——**但它不是 Grace 能開機的 flavor**：Grace 需要 **64K pages**，
`nvidia-64k` 是唯一正确 lineage（证据 [`nvidia-64k-package-state.txt`](evidence/nvidia-64k-package-state.txt)
顯示 generic 4K lineage 并存於同一台）。所以：

- 「最新的核心」和「能開機的核心」在这平台上是**两个不同答案**；
- walk-up 問題（`apt dist-upgrade` 為什麼指向 7.0.0-43-generic？）答完就在指針問題之下：
  它指向 generic 4K，正是**不该開機**的那个。核心选择永远要**先看 flavor**（64K 對 4K），再看版本号。

## 7. 給下一個人的三條規則

1. **開機預設是「指針到子菜单 entry 的字串」，不是「最新版本」。** 用 `GRUB_DEFAULT` 的
   submenu pinning（NVIDIA 自己的验证核心指引），而不是靠 top-level Ubuntu 入口或 `needrestart`。
2. **回滾 = 已安装的 fallback 核心 + 不讓套件管理器把它删掉。** `apt-mark manual` 把 fallback
   lineage 標成明确安装，`apt autoremove` 就不會把它當 unused dependency 清除——這步是
   **保護機制**，不是選配。
3. **換心后從工具的本身验证**（`uname -r` / `/proc/cmdline` / PAGE_SIZE / boot log 对比），
   不從「grub 應該沒問題」的直觉。boot log 看**对比**（新开机 vs 舊开机），逐条归类已知行，
   才能说「没引入风险」。

## 工具

- [`tools/linux/grace/kernel-default-status.sh`](../../tools/linux/grace/kernel-default-status.sh) —
  唯讀：現役指針、已安装 lineage（nvidia-64k vs generic）、`apt-mark` manual 狀態、page size。
