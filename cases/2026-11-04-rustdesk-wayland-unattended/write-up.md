# RustDesk 在 Wayland 每次連線都彈「允許分享螢幕」——「更新正式版」把它弄回來了

> 環境：Ubuntu 26.04.1 LTS、GNOME Shell 50.1、Wayland session、RustDesk **1.5.1**（標準 deb
> 被 `rustdesk-unattended-wayland` 1.5.1 取代）。2026-11-04 於 `peer-a` 實測。
> 先前用 1.5.1 實驗版（nightly 的 unattended 版）修過一次，升級「正式版」後症狀復發。

---

## 0. 結論（先看這個）

**不是設定跑掉，也不是 1.5.1 的 bug，是「更新時裝錯套件」。**

Wayland 不允許應用程式直接抓畫面，標準 `rustdesk` 套件只能走 **XDG Desktop Portal**，
由 `xdg-desktop-portal-gnome` 再請 gnome-shell 彈窗問本機使用者。RustDesk 自己的密碼
**不能代替**這個授權。

免同意的能力放在**另一個套件** `rustdesk-unattended-wayland`，它用 **DRM/KMS 在行程內直接
擷取**（`libdrmtap`），完全不經 portal。

問題是這兩個套件：

- `Conflicts / Replaces / Provides: rustdesk`
- **版本號一模一樣**（都是 1.5.1）

所以用標準 deb 升級＝把免同意版移除，而 `rustdesk --version` 還是印 `1.5.1`、`dpkg -l`
也還有一行 `rustdesk`，看起來完全正常。

---

## 1. 症狀

- 已設定 RustDesk 密碼，但每次有人連進來，主機端仍跳出系統的「允許分享螢幕」視窗。
- 重設密碼、檢查 RustDesk 的 approve 設定，都無效。
- 這台機器「之前明明修好過」。

---

## 2. 先分辨是哪一道門

兩件事很容易混在一起：

| 彈窗長相 | 來源 | 對應開關 |
|---|---|---|
| 系統視窗，問「允許／分享螢幕」 | Wayland portal | 無法用 RustDesk 設定繞過 |
| RustDesk 自己的 UI，問「確認是否要讓對方存取您的桌面？」 | RustDesk `approve_mode` | `~/.config/rustdesk/RustDesk2.toml` |

本案是前者。分辨方法：看 server log 有沒有 portal 握手。

```bash
L=~/.local/share/logs/RustDesk/server/rustdesk_rCURRENT.log
grep -aE "org.freedesktop.portal|wl-stage|portal handshake|User cancelled" "$L" | tail
```

修正前確實有：

```
DEBUG [libs/scrap/src/wayland/pipewire.rs:623] Response from DBus: ... results: {"session_handle": ...}
DEBUG [libs/scrap/src/wayland/pipewire.rs:623] Response from DBus: ... "restore_token": Variant("<REDACTED>")
```

`session_handle` 就是 portal session，`restore_token` 是它想「記住選擇」用的 token
（GNOME 端經常不領情，token 會因登出／重開機／portal 重啟而失效，所以別指望它）。

---

## 3. 關鍵一步：問「現在裝的到底是哪一個」

不要先看版本號，先看套件狀態與**實作檔案**：

```bash
dpkg -l rustdesk rustdesk-unattended-wayland | tail -2
ls /usr/lib/rustdesk/libdrmtap* 2>/dev/null || echo "沒有 DRM 後端 → 標準版"
```

修正前：

```
ii  rustdesk                     1.5.1     ← 標準版（portal 路線）
rc  rustdesk-unattended-wayland  1.5.1     ← 免同意版只剩設定殘留
ls: cannot access '/usr/lib/rustdesk/libdrmtap*': No such file or directory
```

`rc` = 已移除但留下 conffiles。**版本號相同，狀態字母才是真相。**

也可用探針一次問完（本 repo 的 `tools/linux/probe-package-variant.sh`）：

```bash
tools/linux/probe-package-variant.sh rustdesk rustdesk-unattended-wayland '/usr/lib/rustdesk/libdrmtap.so.0*'
```

---

## 4. 修法：裝「同一個 release 的」免同意版

官方每個 release 都同時附標準版與 unattended 版。1.5.1 於 2026-11-01 發布，unattended 版內含
`libdrmtap.so.0.5.12`。

```bash
mkdir -p ~/rustdesk-upgrade && cd ~/rustdesk-upgrade

# 免同意版（要裝的是這個）
curl -LO https://github.com/rustdesk/rustdesk/releases/download/1.5.1/rustdesk-unattended-wayland-1.5.1-x86_64.deb
# 回滾用：同版本的標準版
curl -LO https://github.com/rustdesk/rustdesk/releases/download/1.5.1/rustdesk-1.5.1-x86_64.deb
```

先驗證下載到的東西，**不要盲裝**：

```bash
dpkg-deb -f rustdesk-unattended-wayland-1.5.1-x86_64.deb Package Version Architecture Conflicts Replaces Provides
# 期望 Package: rustdesk-unattended-wayland / Version: 1.5.1 / Architecture: amd64
#      Conflicts: rustdesk / Replaces: rustdesk / Provides: rustdesk

dpkg-deb -c rustdesk-unattended-wayland-1.5.1-x86_64.deb | grep drmtap
# 期望 ./usr/lib/rustdesk/libdrmtap.so.0.5.12（in-process，沒有 drmtap-helper 是正常的）
```

安裝（需要 root）：

```bash
sudo dpkg -i rustdesk-unattended-wayland-1.5.1-x86_64.deb
```

**agent 在沙箱裡的情況**：sandbox 設了 `no_new_privs`，`sudo` 會直接失敗
（`The "no new privileges" flag is set`）。此時不要想辦法繞，改成讓桌面跳 polkit 驗證框：

```bash
pkexec --disable-internal-agent /usr/bin/dpkg -i "$PWD/rustdesk-unattended-wayland-1.5.1-x86_64.deb"
```

預期輸出（重點那兩行）：

```
dpkg: 為了 rustdesk-unattended-wayland，正打算移除 rustdesk ...
Removing rustdesk (1.5.1), to allow configuration of rustdesk-unattended-wayland (1.5.1) ...
設定 rustdesk-unattended-wayland (1.5.1) ...
```

移除舊套件是 `Conflicts/Replaces` 的正常結果；`~/.config/rustdesk/` 不會動，**ID 不變**。

---

## 5. ⚠️ 安裝後確認「跑的是新版本」

postinst 只做 `systemctl enable; systemctl start`。**服務本來就在跑時 `start` 是 no-op**，
舊二進位會繼續服務。本案剛好舊 unit 在置換過程中被卸載，所以是新起的；但不要依賴這個巧合。

```bash
sudo systemctl restart rustdesk     # 單獨一行
```

> **陷阱：不要把 `rustdesk --` 字串放進同一條 shell 指令。**
> unit 的 `ExecStop=pkill -f "rustdesk --"` 會比對整個命令列，連正在執行 restart 的那條
> `bash -c '... rustdesk --version ...'` 都會被 SIGTERM。驗證請另外跑。

---

## 6. 驗證

| 檢查 | 指令 | 結果 |
|---|---|---|
| 套件 | `dpkg -l rustdesk rustdesk-unattended-wayland` | 變體 `ii`，標準版 `ic` |
| DRM 元件 | `ls -l /usr/lib/rustdesk/libdrmtap.so*` | `libdrmtap.so.0.5.12` |
| 後端接管 | `grep -a "drm: consumer cache warmed" <log>` | `drm: consumer cache warmed (1 displays) at startup` |
| portal 不再出現 | `grep -aE "org.freedesktop.portal\|wl-stage" <log>` | 修正後新寫的 log 全空 |
| ID 不變 | `grep '^enc_id' ~/.config/rustdesk/RustDesk.toml` | 與修正前一致（值不公開） |
| 有輸出可抓 | `cat /sys/class/drm/card*/status` | `card1-HDMI-A-1 connected`，對應 `1 displays` |
| 螢幕不休眠 | `gsettings get org.gnome.desktop.session idle-delay` | `0`（DRM 需要 CRTC 保持掃描） |

`drm: consumer cache warmed` 這行是**只有 DRM 版才會印**的證據，出處
`src/server/drm_capturer.rs:2029`。它同時證明「跑的是新二進位」與「後端真的換了」。

**真人連線驗證（2026-11-06 補做）**：從另一台 Ubuntu 26.04.1 / Wayland 機器（ThinkPad P53）
連進這台，兩段 session 都走 DRM，portal 全零：

```
08:58:35  #1526 Connection opened from <PEER-IP>:6938
08:58:36  libdrmtap loaded: /usr/lib/rustdesk/libdrmtap.so.0 -> ...so.0.5.12
08:58:36  drm: opened unprivileged convert context on "/dev/dri/renderD128"
08:58:36  drm: cursor calibration for display 0 (HDMI-A-1): Ok(rect (0,0,1600,900))
08:58:36  new encoder: HWRAM(h264_vaapi, 1600x900)
08:58:43  #1526 Connection closed: Reset by the peer     ← 使用者手動關閉
09:00:06  #231 Connection opened from <PEER-IP>:7114      ← 重連
09:00:09  libdrmtap loaded / new encoder / initial quality: 1.5
```

- 畫面正常（使用者確認，不是黑屏）。
- 重連後同樣走 DRM，沒有退回 portal。
- 修正後所有 log 的 portal 行總數：**0**。

> **方法論教訓**：先前曾「回報已驗證」，但主機端完全沒有 `Connection opened` 那一行——那次連線
> 根本沒進到這台。要判斷「測試到底有沒有發生」，看主機端 log，不要看使用者端的視窗。

---

## 7. 上線後的注意事項

**7.1 讓螢幕保持開啟。** DRM/KMS 需要一個正在掃描輸出的 CRTC；顯示器睡眠或輸出關閉時就沒東西
可抓。

```bash
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
```

真 headless（沒接螢幕）需要虛擬顯示器（dummy HDMI plug、`vkms`、`drm.edid_firmware`）。

**7.2 安全性模型變了。** DRM 擷取等於拆掉「本機有人按允許」那道門，連鎖定畫面、登入畫面都能
被遠端看到。要做的是：固定密碼且夠長、不要隨便對外開放 21118、定期確認誰有 ID。

**7.3 升級紀律。** 每次升級都抓 `rustdesk-unattended-wayland-<版本>-x86_64.deb`，
**不要裝標準版**；兩者版本號相同，非常容易誤裝。升級後重跑第 5、6 節。

---

## 8. 回滾

```bash
sudo dpkg -i ~/rustdesk-upgrade/rustdesk-1.5.1-x86_64.deb
sudo systemctl restart rustdesk
```

回滾就是裝回標準版（它也 `Conflicts` 新套件），設定檔不用動。代價是彈窗回來。

---

## 9. 指令備忘

```bash
# 這個 host 現在是哪一個？
dpkg -l rustdesk rustdesk-unattended-wayland | tail -2
ls /usr/lib/rustdesk/libdrmtap* 2>/dev/null || echo "標準版"

# 服務跑的是不是新二進位？（啟動時間 vs 安裝時間）
systemctl show rustdesk -p MainPID -p ExecMainStartTimestamp

# portal 有沒有再出手？（切換後應該是空的）
grep -acE "org.freedesktop.portal|wl-stage" ~/.local/share/logs/RustDesk/server/rustdesk_rCURRENT.log

# DRM 後端有沒有接管？
grep -a "drm: consumer cache warmed" ~/.local/share/logs/RustDesk/server/rustdesk_rCURRENT.log
```

---

## 10. 上游連結

- 官方部落格（Wayland 無人值守預覽）：<https://rustdesk.com/blog/unattended-remote-access-wayland/>
- 直接擷取的 PR #15420（預設仍是 off，需 variant 套件）：<https://github.com/rustdesk/rustdesk/pull/15420>
- releases（找 `rustdesk-unattended-wayland-*`）：<https://github.com/rustdesk/rustdesk/releases>
