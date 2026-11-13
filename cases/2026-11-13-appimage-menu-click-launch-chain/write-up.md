# AppImage 選單圖示「點了沒反應」：三層獨立的靜默失敗（GNOME 50 / Wayland）

> 環境：Ubuntu 26.04.1 LTS、GNOME Shell 50.1、Wayland、AppImageLauncher **3.0.0-beta-2**
> （git `96cb937`）、Token Monitor **0.91.0**（Electron AppImage）。2026-11-13 診斷與修復，
> 使用者於當日重開機後確認選單點擊恢復正常。
>
> 前置案例：[`2026-11-02-appimage-desktop-structural-repair`](../2026-11-02-appimage-desktop-structural-repair/)
> 已經證明「磁碟上的 entry 正確 ≠ 執行中的 GNOME Shell 會用新的命令」。本案是同一個症狀的
> 第三次出現，但成因多了一層：**AppImageLauncher 的 GUI 中介會破壞 App 的 second-instance 語意**。

---

## 0. 結論（先看這個）

同一個「點了沒反應」其實是**三層各自獨立、都能靜默失敗**的問題，只修一層會讓下一層看起來像沒修：

| # | 層 | 壞在哪 | 指紋 |
|---|---|---|---|
| 1 | 中介層 | AppImageLauncher 的 binfmt interpreter 在 `APPIMAGELAUNCHER_DISABLE` 未設時，會把 AppImage 交給它的 **Qt GUI**（`/usr/bin/AppImageLauncher`）。經這條路啟動時，App 的 `second-instance` 事件**不會被正確送達**，所以「App 已經在跑、視窗被關掉」時再點圖示叫不回視窗 | 點擊後約 1.2 秒結束、exit 0、沒有視窗；journal 只有 Qt 橫幅 |
| 2 | App 層鎖 | Chromium 的 `SingletonLock` / `SingletonSocket` 在「強制結束」或「開機時還開著就重開機」（`/tmp` 清空）後會殘留。冷啟動時新行程誤判已有實例 → 通知失敗 → 直接退出 | CPU 1.07–1.29 s／wall 1.18–1.39 s、peak ~140 MB、**exit 0**、stderr 空 |
| 3 | Shell 快取 | GNOME Shell 把登入當時的 `ShellApp` 命令快取在記憶體。新的 `Gio`/`gtk-launch` 讀到改過的 `Exec=`，選單仍執行舊的 | 選單點擊的日誌顯示**舊**命令，`gtk-launch` 顯示新啟動器 |

三者互相遮蔽：修好 (2) 後，「已開啟時叫不回視窗」還在；修好 (1) 後，「重開機後第一次點」還是死；
而 (3) 讓前兩者的修復看起來完全無效——因為選單根本沒執行你改的那一行。

---

## 1. 症狀

使用者描述（原始）：

> token-monitor AppImage 原本透過 AppImageLauncher 建立捷徑可以點開，token-monitor 連續更新後
> 疊加 Ubuntu 重開機就失效：點應用程式選單的圖示不會啟動，但雙擊 `~/Applications/` 下的
> AppImage 本體可以正常運行。

補充事實（後來問出來的）：

- 關掉視窗後，App **沒有結束**（背景常駐，行程仍在）；
- 之後再點圖示，仍然什麼都沒發生；
- 重開機很多次都一樣。

---

## 2. 先把「啟動鏈」畫出來

```
左鍵點圖示
  └─ gnome-shell 的 ShellApp（登入時讀進記憶體，之後不重讀）   ← 第 3 層
      └─ Exec= 指定的執行檔（可為 AppImage 或 wrapper）
          └─ 若有 binfmt 註冊：kernel 改跑 integrator 的 interpreter
              └─ interpreter：APPIMAGELAUNCHER_DISABLE 未設 → 交給 Qt GUI   ← 第 1 層
                  └─ AppImage runtime（FUSE 掛載 /tmp/.mount_*）
                      └─ App 主行程（Electron）
                          └─ Chromium 單一實例鎖                           ← 第 2 層
```

雙擊檔案管理器是**不同的路徑**：它直接執行檔案（或同樣經過 integrator GUI），不經過 shell 快取。
所以「雙擊可用」不能證明「選單可用」，反之亦然。

---

## 3. 量測方式（先避開三個陷阱）

1. **沙箱會說謊。** agent 的沙箱用獨立 PID namespace，看不到桌面行程；`bwrap` 的 AppArmor
   profile 還會讓 AppImage 執行直接失敗：

   ```
   kernel: apparmor="DENIED" operation="exec" profile="bwrap"
           name="/" comm="binfmt-bypass" requested_mask="x"
   [appimagelauncher-binfmt-bypass/lib] ERROR: failed to execute patched runtime: Permission denied
   ```

   這個 `Permission denied` **不是**使用者的問題（見 playbook 0002）。所有「行程有沒有起來」
   的判斷都必須在主機端做。

2. **agent 自己開的實例會污染實驗。** 我在測試時把 App 開著，之後使用者每次點圖示都是
   「第二實例」→ 1.2 秒退出。連續三筆「沒反應」其實是我造成的。**判斷使用者的點擊之前，先
   在主機端看 `ps`。**

3. **失敗沒有錯誤訊息。** 這一類失敗全部 exit 0、stderr 空，唯一可用的是「CPU/記憶體指紋 +
   有沒有視窗」。

```bash
# 主機端（不是沙箱）看指紋
ps -eo pid,etime,rss,cmd | grep -F '/tmp/.mount_' | grep -v grep
journalctl --user --since -45s --no-pager | grep -iE 'token|binfmt|qt\.'
```

判讀：

| 觀察 | 意義 |
|---|---|
| `Consumed 1.2s CPU over 1.3s wall, ~140M`，無新視窗，無錯誤 | **第二實例路徑**（不是 crash、不是載入失敗） |
| AppImage 的 `[appimagelauncher-binfmt-bypass/interpreter]` 有 `APPIMAGELAUNCHER_DISABLE set` | 走的是「直跑」路徑（好） |
| 只有 `Warning: Ignoring XDG_SESSION_TYPE=wayland …` | 走的是 **Qt GUI** 路徑（第 1 層） |

---

## 4. 三層的證據

### 4.1 第 1 層：GUI 中介讓 `second-instance` 失效

App 本身有實作（從 `app.asar` 取出）：

```js
app.on('second-instance', focusExistingWindow);
```

`focusExistingWindow()` 會 `mainWindow.show()`、`restore()`，trayMode 時 `showPopover()`。
所以「叫不回視窗」不是 App 的邏輯問題。

**控制組**：把 App 的視窗關掉（行程仍在），然後繞過中介、直接執行 App 本體的二進位：

```bash
$ export DISPLAY=:0
$ xwininfo -id 0x1200003 | grep 'Map State'
  Map State: IsUnMapped                       # 使用者關掉視窗，行程還活著

$ /tmp/.mount_Token-*/token-monitor --no-sandbox --ozone-platform=x11 &
$ xwininfo -id 0x1200003 | grep 'Map State'
  Map State: IsViewable                       # 視窗立刻回來
```

同一狀態下，走選單/中介路徑：1.2 秒結束、視窗不動。

結論：**中介改變了 second-instance 的語意**。繞過它的方法不是改 App，而是讓 interpreter 走
「直跑」分支——它認得環境變數 `APPIMAGELAUNCHER_DISABLE`：

```console
$ gio launch ~/.local/share/applications/appimagekit_<id>-Token_Monitor.desktop
[appimagelauncher-binfmt-bypass/interpreter] APPIMAGELAUNCHER_DISABLE set, launching AppImage directly
```

### 4.2 第 2 層：殘留的 Chromium 單一實例鎖

`~/.config/<Product>/` 下有三個符號連結：

```
SingletonLock   -> <host>-<pid>
SingletonSocket -> /tmp/scoped_dirXXXX/SingletonSocket
SingletonCookie -> <random>
```

重開機（`/tmp` 清空）或程式被強制結束後，`SingletonSocket` 指向的路徑已不存在，`SingletonLock`
指向的 pid 也已死。新行程看到鎖 → 嘗試通知 → 連不上 → **exit 0**。

**重現**（不需要真的重開機）：

```bash
APP=~/Applications/Token-Monitor-*.AppImage
P=~/.config/<Product>
rm -rf /tmp/scoped_dirSTALE
ln -sfn <host>-999999        "$P/SingletonLock"
ln -sfn /tmp/scoped_dirSTALE/SingletonSocket "$P/SingletonSocket"
ln -sfn 123456789            "$P/SingletonCookie"

$APP --no-sandbox        # 1.2 秒後結束，沒有視窗、沒有錯誤
```

清掉三個連結後再跑就正常。這解释了「重開機後第一次點必死、之後有時又好了」的間歇性。

### 4.3 第 3 層：GNOME Shell 的命令快取

改完 `Exec=` 之後，選單點擊的 journal 仍然是**舊命令**（只有 Qt 橫幅），而同一時間用 GIO 依
desktop id 啟動卻馬上有新啟動器的記錄：

```bash
$ : > ~/.cache/token-monitor-launcher.log
$ gtk-launch appimagekit_<id>-Token_Monitor      # 讀磁碟上的檔案
$ cat ~/.cache/token-monitor-launcher.log
2026-11-13 22:22:34 argv=[] APPIMAGELAUNCHER_DISABLE=unset     # 啟動器被呼叫了

$ journalctl --user --since -15s | grep -i binfmt
… [appimagelauncher-binfmt-bypass/interpreter] APPIMAGELAUNCHER_DISABLE set, launching AppImage directly
```

但使用者實際點選單（同一分鐘內）的日誌只有：

```
… Token_Monitor.desktop[84172]: Warning: Ignoring XDG_SESSION_TYPE=wayland on Gnome. …
… …-84172.scope: Consumed 1.075s CPU time over 1.181s wall clock time, 140.3M memory peak.
```

→ **磁碟是對的，session 是舊的**。Wayland 沒有「只重啟 shell」這種事，只能登出/重開機
（也可以用新的 desktop id 逼 shell 建立新的 app 物件，代價是選單多一個項目）。

---

## 5. 被否證的假設（別再走一次）

| 假設 | 怎麼否證 | 結論 |
|---|---|---|
| `--no-sandbox` 讓新版 Electron 起不來 | 手動用完全相同的參數（`--no-sandbox --user-data-dir=<fresh>`）啟動 → 完整起來（renderer/gpu/network 都在） | 否證；參數无害 |
| AppImage 壞了 / 版本壞了 | 同一顆 AppImage 雙擊可跑 26 分鐘、RSS 3.7 GB | 否證 |
| binfmt 的 `failed to execute patched runtime: Permission denied` 是元凶 | 同訊息只在 agent 沙箱出現，主機端沒有；AppArmor profile `bwrap` 拒絕 exec | 否證（沙箱假象，playbook 0002） |
| binfmt 註冊本身壞掉 | `systemd-binfmt.service` 正常結束；`/proc/sys/fs/binfmt_misc/appimage-*` 兩個註冊都在 | 否證 |
| 只是「App 已經在跑」 | 乾淨狀態（無任何行程）點擊仍然 1.2 秒退出 | 部分成立（第二層），但不是全部 |
| 只要改 `Exec=` 就好 | 改完後選單仍執行舊命令（第 3 層） | 否證（需要 session reload） |

---

## 6. 修法

四件事，缺一不可：

### 6.1 啟動器 wrapper `~/.local/bin/token-monitor`

```bash
#!/usr/bin/env bash
set -u
APP_DIR="$HOME/Applications"
PROFILE_DIR="$HOME/.config/Token Monitor"

# 1) 抓最新版（integrator 每次更新會改檔名：版本_hash.AppImage）
APP=$(ls -1t "$APP_DIR"/Token-Monitor-*.AppImage 2>/dev/null | head -n1)
[ -x "${APP:-}" ] || { echo "token-monitor: no AppImage in $APP_DIR" >&2; exit 1; }

# 2) 清掉失效鎖（持有者已死，或 socket 不在）
LOCK="$PROFILE_DIR/SingletonLock"; SOCK="$PROFILE_DIR/SingletonSocket"
if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
    pid=$(readlink "$LOCK" 2>/dev/null); pid=${pid##*-}
    alive=0; case "$pid" in ''|*[!0-9]*) : ;; *) kill -0 "$pid" 2>/dev/null && alive=1 ;; esac
    sock=$(readlink "$SOCK" 2>/dev/null); ok=0
    [ -n "$sock" ] && [ -S "$sock" ] && ok=1
    if [ "$alive" -eq 0 ] || [ "$ok" -eq 0 ]; then
        rm -f "$LOCK" "$SOCK" "$PROFILE_DIR/SingletonCookie"
    fi
fi

# 3) 跳過 integrator 的 GUI，少一層會破壞 second-instance 的中介
export APPIMAGELAUNCHER_DISABLE=1
exec "$APP" --no-sandbox "$@"
```

### 6.2 捷徑指向 wrapper

```ini
Exec=/home/<you>/.local/bin/token-monitor %U
TryExec=/home/<you>/.local/bin/token-monitor
```

`Delete this AppImage` 動作保留 integrator 的 `remove` helper，不要一起改。

### 6.3 停掉會改寫捷徑的常駐程式

```bash
sed -i 's/^enable_daemon *= *true/enable_daemon = false/' ~/.config/appimagelauncher.cfg
systemctl --user disable --now appimagelauncherd.service
```

理由：它每次登入/每次 AppImage 更新都會重新整合並**重寫 `.desktop`**，把 `Exec=` 還原成
「直接跑 AppImage」，於是第 1、2 層的保護就沒了。它與修復用的 path unit 也會互相打架。

### 6.4 自我修復 + 一次性 session reload

- `token-monitor-repair`：清失效鎖 + 把 `Exec=`/`TryExec=` 指回 wrapper（`sed '0,/^Exec=/'`
  只改第一個，動作區塊不動）。
- systemd user：`.path` 監看 `~/.local/share/applications`（即時修），`.service` 設
  `WantedBy=default.target`（登入跑一次）。
- **重開機或登出再登入**：讓 GNOME Shell 丟掉舊的 `ShellApp` 命令。

驗證自動修復：手動把 `Exec=` 改回去 → `touch` 目錄 → 3 秒內變回 wrapper。

---

## 7. 驗證

| 檢查 | 修前 | 修後 |
|---|---|---|
| 無實例時點選單 | 1.36 s、exit 0、無視窗 | 啟動器被呼叫，App 起來，視窗 `IsViewable` |
| App 在跑、視窗被關掉時點選單 | 視窗不動 | `IsUnMapped` → `IsViewable` |
| 人工植入失效鎖後啟動 | 靜默退出 | 鎖被清掉，第一次就起來 |
| 選單點擊的 journal 標記 | 只有 Qt 橫幅（GUI 路徑） | `APPIMAGELAUNCHER_DISABLE set, launching AppImage directly` |
| 手動改回 `Exec=` + `touch` | — | ≤3 秒修回 |
| 重開機後使用者實點 | 從更新後就一直壞 | 正常；使用者確認 |

---

## 8. 為什麼不能只改 `Exec=`（給下一個人的檢查順序）

1. **先看行程指紋**：`~1.3 s / ~140 MB / exit 0 / 無視窗` → 直接跳去查 `SingletonLock`，
   不要查 AppImage、不要查 FUSE、不要查 icon。
2. **確認是不是「第二實例」**：`ps` 有沒有既有實例；有 → 這是「叫不回視窗」問題（第 1 層），
   不是「起不來」。
3. **確認執行路徑**：journal 有沒有 `APPIMAGELAUNCHER_DISABLE set`；沒有 → 走 GUI 中介。
4. **確認磁碟 vs session**：`gtk-launch <desktop-id>` 有效但選單無效 → 第 3 層（快取），
   需要重開機/登出。
5. 三層都對但仍然沒反應 → 再回去看 1。

一鍵檢查：

```bash
tools/linux/probe-appimage-launch-chain.sh token-monitor "" "$HOME/.config/Token Monitor"
```

它會依序印出 entry 結構、中介層（binfmt + wrapper 有沒有 `APPIMAGELAUNCHER_DISABLE`）、
鎖的狀態（含「STALE」判定）、視窗 map 狀態，最後給 verdict 與下一步。
