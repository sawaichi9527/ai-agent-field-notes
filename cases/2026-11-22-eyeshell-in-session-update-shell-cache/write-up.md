# eyeShell 0.2.2：session 內更新後，選單點擊執行的是已刪除的舊版路徑

> 環境：Ubuntu 26.04.1 LTS、GNOME Shell 50.1、Wayland、AppImageLauncher **3.0.0-beta-2**
> （git `96cb937`）、eyeShell **0.2.2**（jpackage/Compose AppImage）。2026-11-22 診斷、修復，
> 使用者在重開機後實點選單確認恢復。
>
> 前置案例：同一個症狀在 eyeShell **0.1.9** 已經出現過一次
> （[`2026-11-02-appimage-desktop-structural-repair`](../2026-11-02-appimage-desktop-structural-repair/)
> §6.6），當時用「移除 hidden entry 的 `StartupWMClass` + 重開機」修好。這次證明**重開機只是
> 狀態修復**：只要 `Exec=` 裡有版本號，下一次 session 內更新就會把同一個快取問題重新製造出來。
>
> 相關方法：[playbook 0012](../../playbooks/0012-bisect-the-launch-chain.md)、
> [playbook 0013](../../playbooks/0013-menu-click-noop-is-a-lifetime-question.md)、三層案例
> [`2026-11-13-appimage-menu-click-launch-chain`](../2026-11-13-appimage-menu-click-launch-chain/)。

---

## 0. 結論（先看這個）

**磁碟是對的，session 是舊的。** `eyeshell.desktop` 在 01:29:46 就被修復器改指 0.2.2，但
GNOME Shell 從 20:30 登入起就把 `Exec=` 字串快取住；01:28:46 舊版 AppImage 已被 AppImageLauncher
刪除，所以 01:30:58 的點擊執行的是**不存在的 0.1.9 路徑**，`env` 直接失敗——沒有視窗、沒有
App 日誌、只有一行 journal。

這次真正要修的不是 session，而是**為什麼 `Exec=` 會變**：字串含版本號，每次更新就換一次，
而 shell 快取的 key（desktop id）不變、value 卻過期。永久修法是把 `Exec=` 換成固定路徑的
wrapper（執行時才解析最新版），讓快取的字串永遠有效。

---

## 1. 時間線（全部在同一個登入 session，20:30 登入）

| 時間 | 事件 |
|---|---|
| 20:30 | 使用者登入；當時 `eyeshell.desktop` 的 `Exec=env APPIMAGELAUNCHER_DISABLE=1 "…/eyeShell-0.1.9-x86_64.AppImage"`，Shell 快取這條命令 |
| 01:03:07 | 修復器例行執行，`verify entry eyeshell.desktop … cmd='env … eyeShell-0.1.9 …'` |
| 01:28:46 | `appimagelauncherd: Scheduling for unintegration: …/eyeShell-0.1.9-x86_64.AppImage` |
| 01:29:01 | 修復器：`eyeShell: no AppImage found; skipping entry repair`（此時新檔還是 `*.part`） |
| 01:29:43 | `Integrating: …/eyeShell-0.2.2-x86_64.AppImage`；`ERROR: No icon was generated` |
| 01:29:46 | 修復器 `patched eyeshell.desktop … Exec=/home/…/Applications/eyeShell-0.2.2-x86_64.AppImage`（**磁碟從此刻起是對的**） |
| 01:29:58–01:30:10 | 使用者雙擊 AppImage：走 AppImageLauncher GUI（`appimagelauncher.desktop`，Qt 警告），01:29:59 app 起來，01:30:10 關窗 |
| **01:30:58** | **使用者點選單** → `env: '/home/…/eyeShell-0.1.9-x86_64.AppImage': No such file or directory` |
| 01:47 | （本輪修法：wrapper + 固定 `Exec=` 已寫入，修復器驗證 `cmd='/home/…/.local/bin/eyeshell'`） |
| 01:50 | 使用者重開機（新 session，systemd 1891） |
| 01:52:41 | **使用者再點選單：成功** |

01:52:41 的 journal 就是修好的樣子：

```text
eyeshell.desktop[7893]: [appimagelauncher-binfmt-bypass/interpreter] APPIMAGELAUNCHER_DISABLE set, launching AppImage directly: …
systemd[1891]: Started app-gnome-eyeshell-7893.scope - Application launched by gnome-shell.
eyeshell.desktop[7896]: … INFO io.github.sawaichi9527.eyeshell - eyeShell=0.2.2 java=21.0.13.1 …
```

---

## 2. 取證：磁碟 vs 快取

失敗當下（01:30:58）磁碟上的 entry 已經是 0.2.2：

```console
$ gjs -c 'const {GioUnix}=imports.gi; const a=GioUnix.DesktopAppInfo.new("eyeshell.desktop"); print(a.get_commandline());'
env APPIMAGELAUNCHER_DISABLE=1 "/home/<you>/Applications/eyeShell-0.2.2-x86_64.AppImage"

$ desktop-file-validate ~/.local/share/applications/eyeshell.desktop; echo $?
0
```

但點擊執行的是登入時的快取：

```console
$ journalctl --user --since '2026-11-22 01:28' --no-pager | grep eyeshell.desktop
… eyeshell.desktop[62373]: env: '/home/…/Applications/eyeShell-0.1.9-x86_64.AppImage': No such file or directory
… eyeshell.desktop[62373]: env: use -[v]S to pass options in shebang lines
```

判讀（playbook 0012 的指紋表）：

| 觀察 | 意義 |
|---|---|
| 只有 `env:` 那一行，沒有新的 `app-gnome-*.scope`、沒有 app 日誌 | shell 在 `env` 就結束了，**根本沒啟動 AppImage** |
| `env: use -[v]S …` 也一起出現 | `env` 在抱怨「要執行的東西不存在」之後的殘留訊息，不是第二個問題 |
| 磁碟 `gjs` 讀到 0.2.2、`desktop-file-validate` rc=0 | entry 沒壞、icon 沒壞、AppImage 沒壞 |
| 01:29:46 → 01:30:58 之間磁碟沒再被改 | 「改 `Exec=` 就好」在這 72 秒內已經成立，仍然失敗 |

---

## 3. 為什麼雙擊可以（而且順便證明了 AppImage 與中介都正常）

01:29:58 的雙擊在 journal 裡的 identifier 是 `appimagelauncher.desktop`，不是 `eyeshell.desktop`：

- binfmt interpreter 把 AppImage 交給 AppImageLauncher 的 Qt GUI（案例第 1 層），GUI 再啟動 app；
- 01:29:59 `eyeShell=0.2.2` 起來、01:30:10 正常關窗。

所以「AppImage 壞掉」「mediator 壞掉」這兩個假設同時被否證：**同一顆 0.2.2 走 GUI 中介可以
跑**。雙擊之所以看起來「什麼都正常」，是因為它執行的是你手指指到的那個檔，完全繞過 desktop
entry 與 Shell 快取——它對「選單會不會動」沒有資訊量。

---

## 4. 為什麼 0.1.9 的「重開機就好」這次不算修好

0.1.9 那次的兩個問題：

1. hidden 的 AL entry 與可見 entry 共用 `StartupWMClass` → **結構問題**，已用「hidden entry 移除
   `StartupWMClass`」永久修好；
2. GNOME Shell 快取 0.1.8 的 `ShellApp` 命令 → **狀態問題**，當時靠重開機解除。

第 2 點沒有被「修好」，只是被「清掉」。因為 `Exec=` 裡有版本號：

```
Exec=env APPIMAGELAUNCHER_DISABLE=1 "<home>/Applications/eyeShell-<version>-x86_64.AppImage"
```

每次 AppImageLauncher 整合新版都會改寫這條命令，而下一個 session 內的更新就把它變成
「快取指向已刪除檔案」。0.1.9 → 0.2.2 相隔 10 天，本次更新後 **2 分鐘**就復發。
重開機是重置計時器，不是拆掉計時器。

---

## 5. 修法：讓 `Exec=` 不含版本號

### 5.1 固定 wrapper `~/.local/bin/eyeshell`

```bash
#!/usr/bin/env bash
set -u

app_dir="${HOME}/Applications"
app=""

# 新到舊；跳過 0 位元組／半下載（*.part）與不可執行檔
while IFS= read -r candidate; do
    if [ -s "$candidate" ] && [ -x "$candidate" ]; then
        app="$candidate"
        break
    fi
done < <(ls -1t "$app_dir"/eyeShell-*.AppImage 2>/dev/null)

[ -n "$app" ] || { echo "eyeshell: no executable AppImage in $app_dir" >&2; exit 1; }

# 跳過 AL 的 Qt 中介，直接 exec AppImage（等同雙擊最後走到的路徑）
export APPIMAGELAUNCHER_DISABLE=1
exec "$app" "$@"
```

重點：**路徑本身不變**。`Exec=` 永遠是 `/home/<you>/.local/bin/eyeshell`，Shell 快取的字串因此
永遠有效；版本解析延後到執行時。

### 5.2 可見捷徑

```ini
Exec=/home/<you>/.local/bin/eyeshell
```

（`TryExec` 不寫：帶引號的 `TryExec` 會讓 GLib 直接拒收整個 entry；`StartupWMClass` 與
`Icon=eyeshell` 維持原樣。）

### 5.3 修復器認得這個固定值

`appimage-desktop-fix.py` 原本的邏輯是「把 `Exec=` 改成最新 AppImage」——現在要避免它把 wrapper
改回去：

- spec 增加 `custom_exec`（eyeShell → `~/.local/bin/eyeshell`）；
- `patch_entry(…, custom_exec=fixed_exec)`：custom entry 有固定值就寫固定值，否則才寫
  `env APPIMAGELAUNCHER_DISABLE=1 "<AppImage>"`；
- wrapper 不存在時**不要寫出跑不了的 `Exec=`**：記 warning 並 fallback 回 AppImage 路徑。

驗證：

```console
$ ./scripts/appimage-desktop-fix.py --dry-run
[appimage-desktop-fix] patched eyeshell.desktop -> … Exec=/home/<you>/.local/bin/eyeshell
[appimage-desktop-fix] dry-run complete

$ ./scripts/appimage-desktop-fix.py            # 第二次
[appimage-desktop-fix] no changes needed
```

（冪等很重要：path unit 監看 `~/.local/share/applications`，若每次都「改一下」就會自我觸發。）

### 5.4 一次 session reload

快取只能靠登出／重開機解除（Wayland 沒有「只重啟 shell」）。本次由使用者重開機完成。

---

## 6. 驗證

### 6.1 重開機前（不開視窗）

```console
$ ~/.local/bin/eyeshell --appimage-version
[appimagelauncher-binfmt-bypass/interpreter] APPIMAGELAUNCHER_DISABLE set, launching AppImage directly: …
AppImage runtime version: https://github.com/AppImage/type2-runtime/commit/fedfad5
```

兩個訊息都有用：runtime 版本證明 AppImage 本身可執行；`APPIMAGELAUNCHER_DISABLE set, launching
AppImage directly` 證明**不會再走 AppImageLauncher 的 Qt GUI**（少掉會破壞 second-instance 語意的
中間人）。

另外用假 HOME 驗證「挑最新版」與 fallback，不需要碰真正的 `~/Applications`：

| 案例 | 結果 |
|---|---|
| 同時有 `eyeShell-0.2.2.AppImage`、`eyeShell-0.2.3.AppImage`、`*.2.4…AppImage.part` | 執行到 0.2.3；`.part` 不會被選 |
| wrapper 不存在、spec 有 `custom_exec` | warning + fallback 寫回 `env APPIMAGELAUNCHER_DISABLE=1 "<AppImage>"` |
| 真機第二次執行修復器 | `no changes needed` |

### 6.2 重開機後（使用者實點，01:52:41）

```console
$ journalctl --user --since '-10 min' --no-pager | grep -i eyeshell
01:52:41 eyeshell.desktop[7893]: [appimagelauncher-binfmt-bypass/interpreter] APPIMAGELAUNCHER_DISABLE set, launching AppImage directly: …
01:52:41 systemd[1891]: Started app-gnome-eyeshell-7893.scope - Application launched by gnome-shell.
01:52:43 eyeshell.desktop[7896]: … eyeShell=0.2.2 java=21.0.13.1 …
```

判讀：`eyeshell.desktop` 這一次真的是由 **gnome-shell** 執行、`env` 不再出現、App 自己的日誌
出現、scope 是正常的 `app-gnome-*.scope`。使用者確認視窗出現。

### 6.3 之後每次更新要看的

1. `gjs -c '…DesktopAppInfo.new("eyeshell.desktop").get_commandline()'` 應該**永遠**是
   `/home/<you>/.local/bin/eyeshell`（不是 AppImage 路徑）；
2. 選單點擊的 journal 應該有 `APPIMAGELAUNCHER_DISABLE set, launching AppImage directly`；
3. 不應該再出現 `env: '…': No such file or directory`。

五段鏈一次檢查：

```bash
tools/linux/probe-appimage-launch-chain.sh eyeshell "" "$HOME/.config/eyeShell"
```

---

## 7. 被否證的假設

| 假設 | 怎麼否證 | 結論 |
|---|---|---|
| entry 壞了（缺 `Type`/`Exec`、`Icon` 解析不到） | `desktop-file-validate` rc=0；`gjs` 讀到完整 0.2.2 命令；icon 16–512 全 OK | 否證 |
| AppImage 0.2.2 壞了 | 雙擊可跑（01:29:59 app 起來、01:30:10 關窗）；wrapper `--appimage-version` 也 OK | 否證 |
| AppImageLauncher GUI 中介是元凶 | 雙擊走的正是 GUI 路徑，照樣起來 | 否證（此症狀與第 1 層無關） |
| 只要把 `Exec=` 改對就好 | 磁碟 01:29:46 已正確，01:30:58 仍失敗，且整個 session 之後都失敗 | 否證（需 session reload） |
| 重開機就算修好（0.1.9 的結論） | 0.2.2 在 session 內更新後 2 分鐘就復發 | 否證（那是狀態修復，不是結構修復） |
| 修復器會自動跟上就沒事 | 它 01:29:46 確實跟上了；問題在 shell 讀的是舊字串 | 部分成立，但不足以救選單 |

---

## 8. 可轉移的教訓

| 教訓 | 為什麼可轉移 |
|---|---|
| **`Exec=` 帶版本號＝幫自己裝一個「每次更新就過期」的定時器** | 快取的 key（desktop id）不變、value 會變；任何長命 session + 自動更新都適用 |
| **重開機是狀態修復，不是結構修復** | 沒有改掉「會再次產生同樣狀態」的來源，症狀就會以同樣指紋回來 |
| **`env: '<path>': No such file or directory` 是 shell 快取指紋** | 沒有 App 日誌、沒有 crash、沒有 stderr——只有這一行；別去查 AppImage/FUSE/icon |
| **「雙擊可以」對 entry 沒有資訊量** | 檔案管理器執行你點的檔，不查快取命令 |
| **修復器「靜默一分鐘」是設計，不是 bug** | 下載期間 `*.part` 不匹配 glob，舊檔已移除、新檔未改名；這段時間點選單必失敗 |
| **wrapper 的價值不只是繞過中介，而是讓快取命令恆定** | 治本点在「字串不變」，不在「多一層腳本」 |

---

## 9. 未解／下一步

1. **Token Monitor 是同樣的形狀**：`Exec=…/Token-Monitor-0.95.1_<hash>.AppImage --no-sandbox
   --ozone-platform=x11 %U`，session 內更新同樣會讓快取指向已刪除的檔。它目前的 wrapper 論述
   停在「修 scope 殺子行程」，尚未套用固定路徑的 wrapper。
2. **沒有「不重開機」的乾淨解**：替代方案是改用新的 desktop ID（例如 `eyeShell.desktop`）逼
   Shell 建新物件，但選單會多一個項目，且修復器要認得；不值得。
3. AppImageLauncher 3.0.0-beta-2 仍無法從 jpackage AppDir 抽出 eyeShell 圖示（`No icon was
   generated`）；圖示由修復器從 repo assets 安裝，屬既有問題、非本次症狀。
