# AppImage 桌面捷徑：entry 結構壞掉、兩個 entry、抽不到的圖示（GNOME 50 / Wayland）

> 環境：Ubuntu 26.04.1 LTS、GNOME Shell 50.1、Wayland、**AppImageLauncher 3.0.0-beta-2**
> （git commit `96cb937`）。Token Monitor **0.84.0 → 0.84.1**、eyeShell **0.1.5**（jpackage／Compose
> Desktop AppImage）。2026-11-01 修正，2026-11-02 補測與整理；0.84.1 真實更新已於 2026-11-02 21:47
> 驗證（§6.4）。
>
> 這是本 repo 的第二個 Linux case。第一個
> [`2026-11-02-appimage-dock-gear-linux`](../2026-11-02-appimage-dock-gear-linux/) 記錄的是
> **Gear Lever 4.6.2** 的整合；本工作站**沒有**安裝 Gear Lever（`flatpak list` 沒有
> `it.mijorus.gearlever`，也沒有 `~/.var/app/it.mijorus.gearlever`），實際的 integrator 是
> AppImageLauncher。兩者共享 GNOME 的兩條 identity 規則，但產生的檔名、圖示抽取方式與重複
> entry 行為不同，**修法不能互抄**。

---

## 0. 結論（先看這個）

同一個桌面、兩個 app、兩種看起來不同的症狀，但都指向「entry 本身不可用」：

1. **Token Monitor 不是檔名或 WM_CLASS 對不上，而是 `.desktop` 少掉 `Type`/`Exec`/`Name`。**
   GLib 直接回 `null`，`Gio.AppInfo.get_all()` 看不到它 → 選單沒有這個 app，Dock 只能顯示
   通用齒輪。舊的守衛只改 `Icon=` 與 `StartupWMClass=`，所以永遠「修正成功」但檔案仍然無效。

2. **eyeShell 有兩個 `StartupWMClass` 相同的 entry，而 AppImageLauncher 產生的那個 entry
   指到一個從來沒被抽出的圖示。** GNOME 的 `application_state` 顯示 AL entry 的 `last-seen`
   較新，這與執行中的視窗綁到它一致；`Icon=appimagekit_<id>_eyeshell` 在任何標準尺寸都不存在。
   之後把 AL entry 設成 `NoDisplay=true`，Dock 仍然是齒輪——`NoDisplay` 只影響選單，**不會讓
   已存在的 window binding 消失**。

修法是「entry 結構修復 + 所有 match 的 entry 一起修 + 圖示別名 + 冪等守衛」，不是再手改一次
檔名。

---

## 1. 症狀

| App | 應用程式選單 | Dock |
|---|---|---|
| Token Monitor 0.84.0 | **完全沒有** Token Monitor | 齒輪 |
| eyeShell 0.1.5 | `eyeShell` 與 `eyeShell (1)` 兩個 | 齒輪 |

兩個 app 的 PNG 圖示檔本身都是有效的；Token Monitor 的 1024×1024 圖示就放在
`~/.local/share/icons/hicolor/1024x1024/apps/`，eyeShell 的 16–512 圖示也在。

---

## 2. Token Monitor：entry 不是「檔名不對」，是 GLib 根本載不進來

### 2.1 實際檔案

```ini
[Desktop Entry]
Name=\s(2)
Actions=AppImageLauncher-Remove-AppImage;
X-AppImageLauncher-Version=3.0.0-beta-2 (git commit 96cb937), built on 2025-10-28 22:31:15 UTC
Icon=token-monitor
StartupWMClass=token-monitor
```

沒有 `Type=`、`Exec=`、`Comment=`、`Categories=`、`TryExec=`、`X-AppImage-Identifier=`。
`Name=\s(2)` 也不是正常的 AppImageLauncher 輸出。

### 2.2 量測

```bash
ENTRY=$(ls -t ~/.local/share/applications/appimagekit_*Token_Monitor*.desktop | head -1)

desktop-file-validate "$ENTRY"
# error: required key "Type" in group "Desktop Entry" is not present

gjs -c "const {GioUnix}=imports.gi; print(GioUnix.DesktopAppInfo.new_from_filename('$ENTRY'))"
# null
```

`Gio.AppInfo.get_all()` 會**跳過**這個檔案，所以：

- 規則 1（desktop id）與規則 2（`StartupWMClass`）都不會命中；
- 但這不是 identity 設錯，而是 entry 根本沒有進入 lookup。先跑 identity probe 只會得到
  「MISS」，很容易誤判成檔名／WM_CLASS 問題。

### 2.3 舊守衛的盲點

舊的 `token-monitor-icon-fix.sh` 用 awk 只替換 `[Desktop Entry]` 內的 `Icon=` 與
`StartupWMClass=`，缺少的 `Type`/`Exec` 不會被補。journal 顯示它每次都說：

```text
[token-monitor-icon-fix] 已修正 appimagekit_<id>-Token_Monitor.desktop（Icon=token-monitor, StartupWMClass=token-monitor）
```

但 entry 仍然是無效的。**「有寫入」不等於「有修好」；守衛必須驗證結構。**

### 2.4 用 `ail-cli` 排除 AppImageLauncher

為了確認不是 AL 把檔案寫壞，在隔離的 `HOME`／`XDG_DATA_HOME` 內用 AL 自己的 CLI 重跑整合：

```bash
T=$(mktemp -d)
mkdir -p "$T/home/Applications" "$T/home/.local/share" "$T/home/.config"
cp ~/Applications/Token-Monitor-*.AppImage "$T/home/Applications/tm.AppImage"

HOME=$T/home XDG_DATA_HOME=$T/home/.local/share XDG_CONFIG_HOME=$T/home/.config \
  /opt/appimagelauncher.AppDir/usr/bin/ail-cli integrate "$T/home/Applications/tm.AppImage"

grep -E '^(Name|Type|Exec|Icon|StartupWMClass)=' "$T/home/.local/share/applications/"*.desktop
# Name=Token Monitor (0.84.0) (1)     ← 重名時只加 " (1)"
# Type=Application
# Exec=… --no-sandbox %U
# Icon=appimagekit_<新id>_token-monitor
# StartupWMClass=Token Monitor         ← 原樣沿用 bundle 內的值
```

結論：AL 的正常行為是**保留所有欄位、只改 Name 的重名後綴**；它不會產生 `\s(2)`，也不會
刪掉 `Type`/`Exec`。這個損壞推測來自更早的手動／腳本編輯事故（實際事件未留下紀錄）。守衛
不能假設「AL 寫的檔案一定結構完整」。

---

## 3. eyeShell：兩個 entry 都 match，其中一個圖示是空的

### 3.1 兩個 entry

| 檔案 | Name | Icon | 可見 |
|---|---|---|---|
| `eyeshell.desktop`（手寫） | `eyeShell` | `eyeshell`（16–512 都在） | 是 |
| `appimagekit_<id>-eyeShell.desktop`（AL） | `eyeShell (1)` | `appimagekit_<id>_eyeshell` | 是 |

兩者 `StartupWMClass` 都是 `io-github-<...>-MainKt`（AWT 由主類別推導，實測值）。

### 3.2 AppImageLauncher 的圖示抽取失敗

```console
$ journalctl --user --since "…" | grep -i -A2 appimagelauncher
appimagelauncherd: WARNING: No icons found at "usr/share/icons"
appimagelauncherd: WARNING: Using .DirIcon as default app icon
appimagelauncherd: ERROR: Unable to load image.
appimagelauncherd: ERROR: No icon was generated for: …/eyeShell-0.1.5-x86_64.AppImage
appimagelauncherd: WARNING: Unable to resize the application icon into a 128x128 image: "Unable to load image."
```

eyeShell 的 AppDir 只有根目錄 `eyeshell.png` 和 `.DirIcon` symlink，沒有
`usr/share/icons/hicolor/<size>/apps/eyeshell.png`；AL 的抽取器在這台機器上載入 `.DirIcon`
失敗，於是 entry 的 `Icon=` 指向一個**零尺寸**的名稱。

### 3.3 為什麼「隱藏 AL entry」沒有用

GNOME Shell 的 `~/.local/share/gnome-shell/application_state` 留下：

```xml
<application id="appimagekit_<id>-eyeShell.desktop" score="…" last-seen="<較新>"/>
<application id="eyeshell.desktop" score="…" last-seen="<較舊>"/>
```

執行中的視窗綁到的是 AL entry（`last-seen` 較新，最合理的解釋是視窗綁到它）。之後即使把
AL entry 設成 `NoDisplay=true`，Dock 仍然顯示齒輪——因為 `NoDisplay` 只讓它從選單消失，
**不保證它從 window matching 消失，也不會解除既有的 binding**。只要那個 entry 還在、
`StartupWMClass` 還 match，GNOME 就可能選它，而它的 `Icon=` 仍然不存在。

---

## 4. 舊 probe 為什麼說 RESOLVED

把修正前的兩個 entry 放進隔離的 `XDG_DATA_HOME`，只裝 `eyeshell` 的 48px 圖示，重跑舊版
`tools/linux/probe-desktop-match.sh`：

```console
$ XDG_DATA_HOME=$T/.local/share tools/linux/probe-desktop-match.sh \
    io-github-<...>-MainKt ~/Applications/eyeShell-0.1.5-x86_64.AppImage
app_id: io-github-<...>-MainKt
rule 1 (id == '…'): MISS
rule 2 (StartupWMClass == '…'): appimagekit_<id>-eyeShell.desktop, eyeshell.desktop
verdict: RESOLVED
  - appimagekit_<id>-eyeShell.desktop: icon=appimagekit_<id>_eyeshell …
  - eyeshell.desktop: icon=eyeshell …
exit=0
```

**它說 RESOLVED、exit 0，但第一個 entry 的圖示在所有標準尺寸都不存在。** 原因是 probe 只
重播 identity 的兩條規則，沒有檢查「命中的 entry 的 `Icon=` 是否真的查得到」。這正是這次
要補的洞。

---

## 5. 修法

### 5.1 修復器（冪等）

`appimage-desktop-fix.py`（放在維護 workspace，不屬於本 repo 的 `tools/`，因為它是修復器
不是 probe）對每個 app 做：

1. 找最新的 `~/Applications/<App>-*.AppImage`（> 1 MB，避免半下載檔）；
2. 對每個 `appimagekit_*<App>*.desktop`：
   - 缺 `Type`/`Exec`/`Name` 就**整段重建** `[Desktop Entry]`；
   - 設 `Name` / `Icon` / `StartupWMClass` / `Exec` / `TryExec`；
   - 保留 `Actions=` 與 `[Desktop Action …]` 群組（AppImageLauncher 的移除動作）；
3. 只留一個可見 entry；重複的設 `NoDisplay=true`，但**也把它們的 `Icon=` 修好**；
4. 圖示：
   - 從最新的 1024px 來源產生 16–512 的穩定名稱；
   - 另外產生 `appimagekit_<id>_<icon>` 的 16–512 別名，讓 GNOME 已快取的 GIcon 或
     AL 原生名稱也查得到；
5. 內容沒變就不寫檔；只有真的變更才更新 icon cache / desktop database（避免 path unit
   自我觸發）。

> 為什麼要別名：`application_state` 可能還記著 `appimagekit_<id>_eyeshell` 這個 GIcon；
> 修好 entry 的 `Icon=eyeshell` 不一定會讓已存在的視窗重新查表。把別名也補齊，是最便宜的
> 保險。真正要眼見為憑時，重啟 app 或重新登入仍是最後一步。

### 5.2 systemd 守衛

```ini
# ~/.config/systemd/user/appimage-desktop-fix.path
[Path]
PathModified=%h/.local/share/applications
PathModified=%h/.local/share/icons/hicolor
Unit=appimage-desktop-fix.service
```

`appimage-desktop-fix.service` 是 `Type=oneshot`，執行上面的修復器。已驗證：

- 在 `~/.local/share/applications` 建一個臨時檔再刪掉 → path unit 在數秒內啟動 service；
- service 第二次執行 `no changes needed`（冪等、不迴圈）。

### 5.3 為什麼不是「再改一次檔名」

本工作站是 AppImageLauncher，檔名是 `appimagekit_<id>-Token_Monitor.desktop`；Gear Lever
case 的 `token-monitor.desktop` 不適用。**不同 integrator 會產生不同的檔名／圖示命名**；
真正穩定的是「entry 結構 + 所有 match 的 Icon/WMClass + 冪等守衛」，不是某一種檔名。

---

## 6. 驗證

### 6.1 修正前後

| 檢查 | 修正前 | 修正後 |
|---|---|---|
| `Gio` 解析 Token Monitor entry | `null` | `name='Token Monitor' show=true` |
| `desktop-file-validate`（3 個 entry） | token：缺少 `Type` | 全 OK |
| eyeShell `StartupWMClass` 命中的 entry 數 | 2，且都可見 | 2，1 個可見、1 個 `NoDisplay` |
| AL eyeShell entry 的 `Icon` | `appimagekit_<id>_eyeshell`，0 個尺寸 | `eyeshell`，16–512 |
| 舊 probe 對修正前狀態 | `RESOLVED` / exit 0（盲） | `FAIL` / exit 1（icon missing） |
| 新 probe 對修正後狀態 | — | `RESOLVED (identity + icon asset)` / exit 0 |
| 模擬 AL 改寫 | — | 自動修正；第二次執行 `no changes needed` |
| 模擬 0.84.1 更新 | — | 新 entry 被正規化；probe exit 0 |
| **真實 0.84.1 更新**（2026-11-02 21:47） | AL 先寫一次新 entry（bundle 值） | 守衛兩次修正、舊 entry 移除；probe exit 0 |

### 6.2 新 probe 的輸出

```console
$ tools/linux/probe-desktop-match.sh io-github-<...>-MainKt ~/Applications/eyeShell-0.1.5-x86_64.AppImage
app_id: io-github-<...>-MainKt
rule 1 (id == '…'): MISS
rule 2 (StartupWMClass == '…'): appimagekit_<id>-eyeShell.desktop, eyeshell.desktop
entries matching the window: 2
  - appimagekit_<id>-eyeShell.desktop: show=False icon_ok=True theme:eyeshell sizes=[16, 24, 32, 48, 64, 96, 128, 256, 512] …
      note: hidden (NoDisplay=true) but still matches the window
  - eyeshell.desktop: show=True icon_ok=True theme:eyeshell sizes=[16, 24, 32, 48, 64, 96, 128, 256, 512] …
note: 2 entries match the same app_id; the shell may bind to any of them
verdict: RESOLVED (identity + icon asset)
exit=0
```

Token Monitor：

```console
$ tools/linux/probe-desktop-match.sh token-monitor ~/Applications/Token-Monitor-*.AppImage \
    appimagekit_<id>-Token_Monitor.desktop
rule 2 (StartupWMClass == 'token-monitor'): appimagekit_<id>-Token_Monitor.desktop
entries matching the window: 1
  - …: show=True icon_ok=True theme:token-monitor sizes=[16, 24, 32, 48, 64, 96, 128, 256, 512]
verdict: RESOLVED (identity + icon asset)
exit=0
```

### 6.3 模擬 0.84.1（更新前）

Token Monitor 的 updater 在 2026-11-02 21:03 把 0.84.1 下載到
`~/.cache/token-monitor-updater/pending/`，但當時還沒安裝。用隔離 `HOME` 建一個 0.84.1 的 entry
（新的 `appimagekit_<id>`、`Name=Token Monitor (0.84.1) (1)`、`StartupWMClass=Token Monitor`）
餵給修復器：

```text
patched appimagekit_<id>-Token_Monitor.desktop -> Name=Token Monitor Icon=token-monitor StartupWMClass=token-monitor NoDisplay=false
verify icon token-monitor @16,24,32,… -> OK
```

probe 也回 `RESOLVED (identity + icon asset)` / exit 0。幾小時後這個模擬被真實更新驗證（§6.4）。

### 6.4 真實 0.84.1 更新（2026-11-02 21:47）

Updater 觸發更新後，AppImageLauncher 先 unintegrate 0.84.0、再 integrate 0.84.1；新的
identifier 是 `<id>`。journal：

```text
21:46:55 appimagelauncherd: Scheduling for unintegration: …/Token-Monitor-0.84.0_<hash>.AppImage
21:46:58 appimagelauncherd: Scheduling for (re-)integration: …/Token-Monitor-0.84.1_<hash>.AppImage
21:47:01 appimage-desktop-fix: patched appimagekit_<id>-Token_Monitor.desktop -> Name=Token Monitor Icon=token-monitor StartupWMClass=token-monitor NoDisplay=false
21:47:10 appimagelauncherd: Integrating: …/Token-Monitor-0.84.1_<hash>.AppImage
21:47:10 appimagelauncherd: Extracting usr/share/icons/hicolor/1024x1024/apps/token-monitor.png to …/appimagekit_<id>_token-monitor.png
21:47:10 appimagelauncherd: Cleaning up old desktop integration files
21:47:13 appimage-desktop-fix: patched appimagekit_<id>-Token_Monitor.desktop -> …（第二次）
21:47:13 appimage-desktop-fix: verify icon token-monitor @16,…,512 -> OK
```

結果：

- `~/.local/share/applications/` 只剩新的 `appimagekit_<id>-Token_Monitor.desktop`；舊 0.84.0
  entry 已被 AL 移除。
- `Exec`/`TryExec` 指向 `~/Applications/Token-Monitor-0.84.1_<hash>.AppImage`；
  `Name=Token Monitor`、`Icon=token-monitor`、`StartupWMClass=token-monitor`、`NoDisplay=false`。
- `appimagekit_<id>_token-monitor.png` 的 16–512 別名已生成。
- `desktop-file-validate` OK；probe 回 `RESOLVED (identity + icon asset)` / exit 0。
- 再跑一次修復器：`no changes needed`。

觀察：AL 的 integration 是**分段**的（先寫 entry，稍後 deferred operations 再寫一次），所以
守衛在這次更新跑了三次、修了兩次才收斂。冪等 + path unit 讓這是安全的；如果守衛只做一次，
第二次 AL 寫回時就會復發。

---

## 7. 沒有驗證到的事

- **Dock 截圖**：沒有做。驗證到「Gio identity + GtkIconTheme 每個尺寸都查得到」，
  這是 shell 決定圖示的同一組查表；但沒有實際看畫面。
- **Wayland 原生 app_id**：eyeShell 是 XWayland（`WM_CLASS` 可讀）；Token Monitor 走原生
  Wayland 時沒有直接讀 app_id。兩者的 `StartupWMClass` 都是既有實測值，修法只依賴字串。
- **GNOME 對已存在視窗的圖示快取**：修 entry 後，執行中的視窗不一定立刻換圖示；重啟 app
  或重新登入是最後一步。
- **0.84.1 真實更新**：已於 2026-11-02 21:47 發生並驗證（見 §6.4）；沒有再手動改任何 entry。

---

## 8. 上游與後續

1. **AppImageLauncher 3.0.0-beta-2 的 icon extraction**：對這個 jpackage AppDir（只有根
   `eyeshell.png` + `.DirIcon`）會 `Unable to load image`。把七個尺寸放到
   `usr/share/icons/hicolor/<size>/apps/eyeshell.png` 後，用 `ail-cli` 在隔離 `HOME` 驗證，
   AL 會把它們全部抽出並命名為 `appimagekit_<id>_eyeshell`。這是 eyeShell 打包層的正解，
   但這次沒有重建正在使用的 AppImage。
2. **Token Monitor bundle 的 `StartupWMClass=Token Monitor`**：app_id 是 `token-monitor`，
   上游應改掉或移除；AL 會原樣複製。
3. **不要用 `NoDisplay` 當「讓 entry 不再 match」的手段**：它只影響選單，不保證解除既有的
   window binding。重複 entry 要修好圖示，或真的移除（但 AL 會重建，所以還是要守衛）。
4. **本 repo 第一個 Linux case 是 Gear Lever**：若要在本機重現，請先確認 integrator；
   `token_monitor.desktop` 與 `appimagekit_<id>-Token_Monitor.desktop` 是不同工具的形狀。

---

## 9. 指令備忘

```bash
# 這台機器用哪個 integrator？
flatpak list | grep -i gearlever || echo "no Gear Lever"
/opt/appimagelauncher.AppDir/usr/bin/ail-cli --version

# entry 結構
ENTRY=$(ls -t ~/.local/share/applications/appimagekit_*Token_Monitor*.desktop | head -1)
desktop-file-validate "$ENTRY"
gjs -c "const {GioUnix}=imports.gi; print(GioUnix.DesktopAppInfo.new_from_filename('$ENTRY'))"

# 兩個 app 的 identity + icon + 無效 entry
tools/linux/probe-desktop-match.sh token-monitor ~/Applications/Token-Monitor-*.AppImage "$ENTRY"
APP_ID=$(grep -h '^StartupWMClass=' ~/.local/share/applications/appimagekit_*eyeShell*.desktop | head -1 | cut -d= -f2)
tools/linux/probe-desktop-match.sh "$APP_ID" ~/Applications/eyeShell-*.AppImage

# AL 的圖示抽取錯誤
journalctl --user --since "today" --no-pager | grep -i -E "appimagelauncher|No icon was generated"

# GNOME 記得的 app id（唯讀）
strings ~/.local/share/gnome-shell/application_state | grep -i -E "eyeshell|token"

# 重建修正前的 probe 狀態（隔離 XDG）
T=$(mktemp -d); mkdir -p "$T/.local/share/applications" "$T/.local/share/icons/hicolor/48x48/apps"
cp ~/.local/share/applications/appimagekit_*eyeShell*.desktop.bak-before-fix \
   "$T/.local/share/applications/appimagekit_<id>-eyeShell.desktop"
cp ~/.local/share/applications/eyeshell.desktop.bak-before-fix "$T/.local/share/applications/eyeshell.desktop"
cp ~/.local/share/icons/hicolor/48x48/apps/eyeshell.png "$T/.local/share/icons/hicolor/48x48/apps/"
XDG_DATA_HOME=$T/.local/share tools/linux/probe-desktop-match.sh "$APP_ID" ~/Applications/eyeShell-*.AppImage
```
