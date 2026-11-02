# Token Monitor AppImage 在 Ubuntu Dock 顯示齒輪圖示（GNOME 50 / Wayland）

> 環境：Ubuntu 26.04.1 LTS、GNOME Shell 50.1、Wayland session、Gear Lever 4.6.2（flatpak）、
> Token Monitor **0.84.0** AppImage。2026-11-02 實測。
> 舊版（0.69.0）修過一次，這是**更新後回歸**的第二次。

---

## 0. 結論（先看這個）

**齒輪不是圖示檔壞了，是「視窗認不出自己是哪個應用程式」。**

GNOME 只用兩條規則把視窗對到 `.desktop`：

1. 檔名（desktop id）**等於**視窗 app_id 加 `.desktop`
2. `StartupWMClass` **等於**視窗 app_id（不分大小寫）

實際 app_id 是 `token-monitor`；當時裝的檔案是 `token_monitor.desktop`（底線）且
`StartupWMClass=Token Monitor`（空格＋大寫）。**兩條都不中** → 退回
`application-x-executable`，Yaru 主題裡就是齒輪。

而它會「又」發生，是因為 **Gear Lever 每次更新 AppImage 都會重建這個檔案**，並且把
AppImage 內建 desktop 檔裡**上游寫錯的** `StartupWMClass` 原樣複製進來。手改檔名只能撐到
下次更新。

---

## 1. 症狀

- 從 AppImage 啟動，視窗正常、標題正確，但 Dock 是灰色齒輪。
- `~/.local/share/applications/token-monitor.desktop`（上次手動建立的）在更新後消失，
  變成 `token_monitor.desktop`。
- 圖示檔 `~/Applications/.icons/token_monitor` 一直是正確的 1024×1024 藍色 Σ。

---

## 2. 量測：先問「視窗真正的 app_id 是什麼」

不要先看圖示，也不要先改檔名。量測視窗本身（Electron 用 `--ozone-platform=x11` 強制走
XWayland，才能用 `xprop` 讀）：

```bash
export DISPLAY=:0
HOME=/tmp/tokmon XDG_CONFIG_HOME=/tmp/tokmon/.config \
  APPIMAGE_EXTRACT_AND_RUN=1 \
  ~/Applications/token_monitor.appimage --no-sandbox --ozone-platform=x11 &
sleep 14
for id in $(xprop -root _NET_CLIENT_LIST | sed 's/.*# //' | tr -d ' ' | tr ',' '\n'); do
  xprop -id "$id" WM_CLASS _NET_WM_NAME
done
```

結果：

```
WM_CLASS(STRING) = "token-monitor", "token-monitor"
_NET_WM_NAME(UTF8_STRING) = "Token Monitor"
```

`WM_CLASS` 的**第二個**字串才是 GNOME 用的 app_id（Electron 由執行檔名 / package.json
`name` 決定，本例 `token-monitor`）。

> 誠實註記：以上是 XWayland 的量測值。Wayland 原生視窗的 app_id 沒有直接觀測（GNOME Shell
> 沒有開放查詢介面），但兩者都是同一組字串，且修法只依賴這個字串，不依賴 session 類型。

---

## 3. GNOME 的兩條規則（不開 GUI 也能驗）

用 GIO 模擬 shell 的查表，這是可腳本化的回歸檢查：

```python
import gi; gi.require_version('Gio','2.0')
from gi.repository import Gio

app_id = "token-monitor"

# 規則 1：desktop id
info = Gio.DesktopAppInfo.new(f"{app_id}.desktop")     # None = 找不到
print("rule1:", "FOUND" if info else "MISS")

# 規則 2：StartupWMClass
hits = [a.get_id() for a in Gio.AppInfo.get_all()
        if isinstance(a, Gio.DesktopAppInfo)
        and (a.get_startup_wm_class() or '').lower() == app_id]
print("rule2:", hits or "MISS")
```

修正前：規則 1 `MISS`、規則 2 `MISS`（已安裝的 `token_monitor.desktop` 其
`StartupWMClass` 是 `Token Monitor`，不是 `token-monitor`）。
修正後：`FOUND` / `['token-monitor.desktop']`。

---

## 4. 為什麼手改只能撐一次更新（Gear Lever 原始碼）

Gear Lever 4.6.2 的 flatpak 內
`.../share/gearlever/gearlever/providers/AppImageProvider.py`，`install_file()`：

```python
# 檔名：取自 AppImage 內建 desktop 的 Name
appimage_filename = extracted_appimage.desktop_entry.getName()   # "Token Monitor"
appimage_filename = appimage_filename.lower().replace(' ', '_')  # "token_monitor"
...
prefixed_filename = os.path.splitext(appimage_filename)[0]       # "token_monitor"
dest_desktop_file_path = f'{applications_dir}/{prefixed_filename}.desktop'

# 內容：整個 AppImage 內建 desktop 檔複製過來
jd_desktop_entry = JdDesktopEntry.from_file(extracted_appimage.desktop_file.get_path())
jd_desktop_entry.TryExec = dest_appimage_file.get_path()
jd_desktop_entry.Exec = shlex.join([dest_appimage_file.get_path(), *exec_arguments])
jd_desktop_entry.Icon = dest_icon_path
# StartupWMClass 沒有被覆寫 → 原樣沿用上游（錯的）值
```

而 0.84.0 AppImage 內建的 `token-monitor.desktop` 本身就寫著：

```ini
Icon=token-monitor
StartupWMClass=Token Monitor     # ← 上游的錯，app_id 其實是 token-monitor
Name=Token Monitor
```

**兩個獨立錯誤，任何一個修好都能讓 bug 消失**，所以它才會時好時壞：

| 錯誤 | 後果 | 誰負責 |
|---|---|---|
| 檔名 `token_monitor` ≠ id `token-monitor` | 規則 1 不中 | Gear Lever（由 `Name` 推導） |
| `StartupWMClass=Token Monitor` ≠ `token-monitor` | 規則 2 不中 | 上游 AppImage 打包 |

---

## 5. 修法 A：立即修正（一次）

```bash
A=~/.local/share/applications
rm -f "$A/token_monitor.desktop"

cat > "$A/token-monitor.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Token Monitor
Comment=Real-time token, cost, and AI limits widget with multi-device sync for Claude Code, Codex, OpenCode and more.
Icon=/home/<you>/Applications/.icons/token_monitor
TryExec=/home/<you>/Applications/token_monitor.appimage
Exec=/home/<you>/Applications/token_monitor.appimage --no-sandbox %U
Terminal=false
Categories=Development;
StartupWMClass=token-monitor
StartupNotify=true
X-AppImage-Version=0.84.0
X-AppImage-Name=Token Monitor
EOF

update-desktop-database "$A"
```

重點只有兩個：**檔名 `token-monitor.desktop`**、**`StartupWMClass=token-monitor`**。

---

## 6. 修法 B：自動修復守衛（避免下次更新又壞）

因為 Gear Lever 一定會再重建檔案，正確做法是「守著它」而不是「改它」。

`~/.local/bin/token-monitor-dock-fix.sh`：把任何 `Exec`/`TryExec` 指向
`token_monitor.appimage` 的 desktop 檔正規化（改名、改 `StartupWMClass`、去重），
內容沒變就不寫檔（避免自我觸發迴圈）。

`~/.config/systemd/user/token-monitor-dock-fix.path`：

```ini
[Path]
PathModified=%h/.local/share/applications
```

`token-monitor-dock-fix.service`（oneshot）執行上面的腳本。啟用：

```bash
systemctl --user daemon-reload
systemctl --user enable --now token-monitor-dock-fix.path
```

停用：`systemctl --user disable --now token-monitor-dock-fix.path`

---

## 7. 驗證

| 檢查 | 結果 |
|---|---|
| GIO 規則 1 | `FOUND` |
| GIO 規則 2 | `token-monitor` |
| 條目數 | 1（選單不會出現兩個 Token Monitor） |
| 模擬 Gear Lever 寫回錯誤檔 | 4 秒內自動改名並修正 |
| 模擬同時兩筆 | 自動移除重複 |

**沒有做到的事**：Dock 截圖。驗證只到「shell 的查表會命中」，圖示是這條查表的結果。
要眼見為憑就啟動一次 App。

---

## 8. 上游問題（未提交）

1. AppImage 內建 `token-monitor.desktop` 的 `StartupWMClass=Token Monitor` 應改為
   `token-monitor`（或直接移除該鍵，檔名本身已可命中規則 1）。
   影響所有用 Gear Lever / AppImageLauncher 整合的使用者。
2. Gear Lever 不該原樣複製 `StartupWMClass`；它其實可以從執行中的視窗量到真正的
   `WM_CLASS`，或至少比對檔名與 `Name` 的落差。

---

## 9. 指令備忘

```bash
# 看目前裝了哪些相關 desktop 檔
ls ~/.local/share/applications | grep -i token

# 看某個 desktop 檔的關鍵欄位
grep -E '^(Name|Exec|Icon|StartupWMClass)=' ~/.local/share/applications/token-monitor.desktop

# 看 Gear Lever 最近做了什麼（它會記錄重建/刪除哪個檔案）
tail -40 ~/.var/app/it.mijorus.gearlever/.local/state/gearlever/gearlever.log
```
