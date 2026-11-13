# Token Monitor 0.91.0：選單點了「沒反應」——entry 是好的，是自我重啟的子行程被 app scope 殺掉

> 環境：Ubuntu 26.04.1 LTS、GNOME Shell 50.1、Wayland、AppImageLauncher 3.0.0-beta-2（git
> `96cb937`）、Token Monitor **0.91.0**（Electron 45.2.1 / Chrome 156 AppImage）。
> 2026-11-13 晚上回報、修正；使用者重開機後確認選單可啟動。
>
> 同一天另有一份調查記錄了同一個症狀的另外三層（integrator GUI 吞掉 `second-instance`、殘留的
> Chromium `SingletonLock`、Shell 快取），指紋是 ~1.3 秒退出：
> [`../2026-11-13-appimage-menu-click-launch-chain/`](../2026-11-13-appimage-menu-click-launch-chain/)。
> 兩者是同一條啟動鏈上的不同層，不互相取代。
>
> 前情：同一台機器的身分／圖示問題在
> [`../2026-11-02-appimage-desktop-structural-repair/`](../2026-11-02-appimage-desktop-structural-repair/)
> （entry 結構、重複 entry、`ShellApp` 快取）。本篇是另一個獨立成因的「點了沒反應」。

---

## 0. 結論（30 秒）

| 檢查 | 結果 |
|---|---|
| `.desktop` 結構 | 正常；`desktop-file-validate` OK、`Gio` 載得到、`Exec` 指向存在的 0.91.0 |
| 圖示 16–512 | 全部查得到 |
| 點擊後有沒有啟動？ | **有**，journal 出現 `app-gnome-…-Token_Monitor-<pid>.scope` |
| 活多久？ | **2.2–2.8 秒**，然後 scope 結束（`Consumed ~2.2 s CPU`） |
| app 自己的 log？ | **一行都沒有**（舊版會有 `[collector] Watching …`） |
| 每次點擊的 AppImage 掛載數 | **1 個**（兩段式啟動應該有 2 個） |

根因不在 entry：0.91.0 的 `launch.js` 為了選 XWayland，會 **spawn 一個 detached 子行程再
`app.exit(0)`**；GNOME 把 app 放在 transient `app-gnome-*.scope`，scope 的 `KillMode` 預設是
`control-group`，父行程一結束 systemd 就回收整個 cgroup，子行程還沒開視窗就被殺。子行程的
stdio 是 `'ignore'`，所以連錯誤訊息都不會進 journal。

修法：`Exec` 直接帶 `--ozone-platform=x11`，讓 wrapper 判斷「backend 已指定」而**不** fork；
修復腳本同步產生這個旗標，避免 path unit 在下次更新後把它改回去。

---

## 1. 症狀與錯誤的第一直覺

- 應用程式選單看得到 `Token Monitor`，圖示正常。
- 點下去：沒有視窗、沒有系統匣圖示、沒有錯誤對話框。
- 直接在終端機／檔案管理器執行 0.91.0，「理論上」會因為沒有 app scope 回收而正常，但**這次
  沒有實測**；可以確定的是 0.88.0 在更新前有正常執行過（journal 留下 5 分鐘的 session），
  而 0.91.0 從安裝後就沒有任何一行 app log。

因為前兩個 case 都是 entry 問題，第一直覺會去改 `Icon`/`StartupWMClass`/`Exec`。這次 entry
是乾淨的：

```console
$ desktop-file-validate ~/.local/share/applications/appimagekit_<id>-Token_Monitor.desktop
$ gjs -c 'const {GioUnix}=imports.gi; const a=GioUnix.DesktopAppInfo.new("appimagekit_<id>-Token_Monitor.desktop"); print(a.get_commandline())'
/home/<you>/Applications/Token-Monitor-0.91.0_<hash>.AppImage --no-sandbox %U
```

`Exec` 指向的檔案存在、`TryExec` 可執行、圖示 16/24/32/48/64/96/128/256/512 全部 OK；開機時
修復器也回報 `no changes needed`。**entry 這條線可以結束，但要先證明「行程沒活下來」，而不是
「entry 沒被執行」。**

---

## 2. 量測：有啟動，但活不過 3 秒

點一次選單，然後只看三件事：scope、mount、app log。

```console
$ journalctl --user --since '-5 min' --no-pager | grep -E 'Token_Monitor|collector'
23:36:10 appimagekit_<id>-Token_Monitor.desktop[4681]: Warning: Ignoring XDG_SESSION_TYPE=wayland on Gnome. Use QT_QPA_PLATFORM=wayland to run on Wayland anyway.
23:36:10 systemd[1866]: Started app-gnome-appimagekit_<id>…-Token_Monitor-4681.scope - Application launched by gnome-shell.
23:36:13 systemd[1866]: app-gnome-appimagekit_<id>…-Token_Monitor-4681.scope: Consumed 2.173s CPU time over 2.590s wall clock time, 283.1M memory peak.
```

再點一次，數字幾乎一樣：`2.254s CPU / 2.831s wall`、`137.9M`。**每次都停在 2–3 秒**，而且
沒有 `[collector]`、沒有 `Checking for update`——那些是 0.88.0 每次啟動都會印的。

AppImage 的 FUSE 掛載也對不上：

```console
$ journalctl --since '-5 min' --no-pager | grep -i 'mount_.*Token'
23:36:13 systemd[1]: tmp-.mount_Token-<rand>.mount: Deactivated successfully.
```

一次點擊只有一個掛載被卸載。若啟動流程是「父行程 → 再 spawn 一次 AppImage」，第二段應該有
自己的掛載；只有一個代表第二段**在掛載之前就結束了**。

還有一個容易誤導的線索：那行 `Ignoring XDG_SESSION_TYPE=wayland` 是 **AppImageLauncher 的
Qt binfmt-bypass** 印的，不是 app 印的（app 是 Electron/Chromium）。它不能拿來判斷 app 用哪個
display backend，也不代表 app 已經跑到主程式。

---

## 3. 根因：`startWithXWayland` 的 detached 子行程

0.91.0 的 `package.json` 主入口是 `src/electron/launch.js`：

```js
// launch.js
const { app } = require('electron');
const { startWithXWayland } = require('./linuxDisplayServer');
startWithXWayland({ app, start: () => require('./main') });
```

`linuxDisplayServer.js` 的註解說明了動機：Wayland 不讓 client 決定視窗位置，widget 的
windowBounds 存不回正確位置，所以要把視窗改走 XWayland。做法是**在建立任何視窗之前**
重新執行自己：

```js
// 節錄：packaged 分支
const executable = packaged && env.APPIMAGE ? env.APPIMAGE : execPath;
const args = argv.slice(1);
args.splice(…, 0, '--ozone-platform=x11');
const child = spawn(executable, args, {
  detached: packaged,
  stdio: packaged ? 'ignore' : 'inherit'
});
child.once('spawn', () => { spawned = true; if (packaged) { child.unref(); app.exit(0); } });
```

在一般 shell／雙擊啟動時，父行程退出、子行程留下來，看起來完全正常。但從 GNOME 選單啟動時：

1. gnome-shell 用 transient scope 啟動 app（`app-gnome-<desktop-id>-<pid>.scope`）；
2. scope 的 transient unit 檔只有 `Description` 與 `CollectMode=inactive-or-failed`，沒有
   `KillMode` 覆寫 → systemd 對 scope 的預設是 `control-group`；
3. `detached: true` 只讓子行程成為新 session 的 leader，**cgroup 沒有變**；
4. 父行程 `app.exit(0)` → scope 的主要行程結束 → systemd 停止 scope、殺掉 cgroup 裡剩下的
   行程；
5. 子行程的 stdout/stderr 是 `/dev/null`，所以整個失敗在 journal 裡是靜音的。

時間軸與觀測一致：Electron 啟動約 2 秒 → 執行 `launch.js` → spawn 子行程 → 父行程退出 →
scope 在 2.2–2.8 秒被回收 → 子行程沒有機會掛載 AppImage。沒有 `[display] XWayland relaunch
failed` 的警告，代表 `spawn` 本身成功（失敗時程式會 fallback 回 `start()` 並印出該警告）。

> 另一個會產生同樣「無聲死亡」的可能：`$APPIMAGE` 若指進父行程的 transient mount，子行程
> 在父行程卸載後找不到 `resources.pak` 也會直接結束。這次沒有辦法區分兩者（子行程的輸出被
> 丟棄）；但**跳過 relaunch** 的修法同時涵蓋兩種情況。

---

## 4. 修法：把 wrapper 要的旗標放在 `Exec`

不要改 AppImage、不要改 entry 名稱，只要讓 `shouldUseXWayland()` 一開始就回 `false`：

```ini
Exec=/home/<you>/Applications/Token-Monitor-0.91.0_<hash>.AppImage --no-sandbox --ozone-platform=x11 %U
```

`switchArguments(argv)` 看到 `--ozone-platform=x11` 就不會 fork，app 直接在 gnome-shell 啟動的
那個行程裡跑（而且正是 wrapper 本來想用的 XWayland backend）。

修復器 `appimage-desktop-fix.py` 的 `TOKEN_MONITOR["exec_suffix"]` 同步改成
`" --no-sandbox --ozone-platform=x11 %U"`。這一步不能省：systemd path unit 監看
`~/.local/share/applications`，若只改 entry，守衛會在數秒內用舊的 `exec_suffix` 蓋回去。

---

## 5. 驗證，以及一次值得記錄的假陰性

### 5.1 同一個 session 內改了 `Exec` → 看起來完全沒修好

改完 entry（23:44）、path unit 確認 `no changes needed` 後，從選單再點一次：

```console
23:45:27 Started app-gnome-…-Token_Monitor-8624.scope
23:45:29 …scope: Consumed 2.307s CPU time over 2.197s wall clock time, 137.8M memory peak.
```

跟修正前一模一樣：2.2 秒、沒有 app log。**但這是 `ShellApp` 快取，不是修正失敗。**
GNOME Shell 把舊的 command line 快取在 session 裡（eyeShell 0.1.9 已記錄過同一件事）；
`Gio` 新行程讀到的是新 `Exec`，選單點擊用的還是舊的。

推論方式：如果 Shell 真的用了新 `Exec`，wrapper 就不會 fork，app 會活下來並印出
`[collector]`；沒有這些輸出，代表 relaunch 仍然發生 → 執行的是舊 command。

### 5.2 重開機後

```console
23:48:28 appimagekit_<id>-Token_Monitor.desktop[4549]: Warning: Ignoring XDG_SESSION_TYPE=wayland on Gnome. …   ← 仍是 launcher wrapper
23:48:32 appimagekit_<id>-Token_Monitor.desktop[4644]: [4644:…:ERROR:media/gpu/vaapi/vaapi_wrapper.cc:1796] vaInitialize failed: unknown libva error
23:48:33 appimagekit_<id>-Token_Monitor.desktop[4568]: [collector] Watching ~/.local/share/opencode (native events)
23:48:33 appimagekit_<id>-Token_Monitor.desktop[4568]: [collector] Watching ~/.dsh/sessions (native events)
23:48:47 appimagekit_<id>-Token_Monitor.desktop[4568]: Checking for update
23:48:48 appimagekit_<id>-Token_Monitor.desktop[4568]: Update for version 0.91.0 is not available (latest version: 0.91.0, downgrade is disallowed).
```

`/sys/fs/cgroup/…/app.slice/app-gnome-…Token_Monitor-<pid>.scope` 在 23:51 仍然存在，代表行程
持續執行；使用者確認選單點擊後視窗正常出現。

**教訓：改的是 Shell 快取的東西時，同一個 session 的「沒變」不能當作反證。** 兩次點擊的
journal 一模一樣，差別只在「這次跑的是舊 Exec」——這是一個沒有鑑別力的實驗。

---

## 6. 轉移性教訓

| 教訓 | 為什麼可轉移 |
|---|---|
| **entry 合法 ≠ 行程活著** | 「選單沒反應」有兩個完全不同的問題層次；先證明行程有起來、且活超過幾秒 |
| **app scope 的壽命就是答案** | GNOME 的 transient scope 在主要行程結束時殺掉 cgroup；任何「fork 一個 helper 再退出」的啟動器都會中 |
| **detached 不會離開 cgroup** | `setsid`/`detached` 只改 session，不改 cgroup；systemd 的 `KillMode=control-group` 照樣殺 |
| **mount 數量是兩段式啟動的指紋** | 一次點擊只有一個 AppImage 掛載，代表第二段沒有走到 runtime |
| **launcher 的輸出不是 app 的輸出** | AppImageLauncher 的 Qt bypass 與 Electron app 共用同一個 journal identifier，但那行 warning 不代表 app 的 backend |
| **`stdio: 'ignore'` 讓失敗靜音** | 子行程的錯誤不會進 journal；除錯時要自己把 stdout/stderr 打開，或直接跳過該路徑 |
| **`--ozone-platform=x11` 放在 `Exec`** | app 自己 relaunch 時帶的參數，就是它需要的參數；讓 wrapper 走「已指定」分支，比事後補救可靠 |
| **修復器要一起改** | 只改 entry，path unit 會用舊規則蓋回去；修正要落在產生 entry 的地方 |
| **改 `Exec` 後要換 session 再驗證** | ShellApp 快取會讓修正前後的 journal 長得一樣；這是假陰性，不是修不好 |

---

## 7. 沒有驗證到的事 / 上游

- **systemd 直接殺掉子行程**：沒有在 scope 還活著時即時抓 `cgroup.procs`／signal；結論是從
  「scope 2.2 秒結束 + 只有一個 mount + 沒有 app log + `KillMode` 預設」推出來的。
- **子行程實際死在哪一步**：exec、掛載、或 Electron 初始化，無法區分（stdio 被丟棄）。
- **上游**（`Javis603/token-monitor`）：`startWithXWayland` 的 packaged 分支有兩個可改進點：
  1. 子行程的 stdio 不要 `'ignore'`（至少把 stderr 導到檔案/journal）；
  2. 不要用「父行程立刻退出」的方式交出所有權；讓父行程等到子行程 `ready`，或把子行程放進
     自己的 transient unit，才不會被 app scope 連坐。
  若上游修掉，`Exec` 的 `--ozone-platform=x11` 仍然無害（只是明確指定 backend）。
- **Electron 45 / GNOME 50 以外的組合**：KDE 的啟動器如果沒有 systemd app scope，同樣的
  relaunch 不會被殺；所以這個 bug 可能只在 GNOME（或任何 scope-based launcher）出現。

---

## 8. 指令備忘

```bash
ENTRY=$(ls -t ~/.local/share/applications/appimagekit_*Token_Monitor*.desktop | head -1)

# entry 是否真的可載入
desktop-file-validate "$ENTRY"
gjs -c 'const {GioUnix}=imports.gi; const a=GioUnix.DesktopAppInfo.new("'"$(basename "$ENTRY")"'"); print(a.get_commandline())'

# 點一次之後：scope 有沒有開始／結束、活多久、app 有沒有輸出
journalctl --user --since '-5 min' --no-pager | grep -E 'Token_Monitor|collector'

# 這次啟動的 AppImage 掛載（兩段式啟動應該有兩個）
journalctl --since '-5 min' --no-pager | grep -i 'mount_.*Token'

# 行程是否還活著（不必看 GUI）
ls -d /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice/app-gnome-*Token* 2>/dev/null

# 修正後必須換 session 再測：登出再登入或重開機
```
