# apt update 每次收尾三個 Notice：兩個 i386 跳過、一個 Signed-By 空白

> 環境：Ubuntu 26.04.1 LTS（`resolute`）、apt 3.2.1、`i386` 為 foreign architecture（保留給
> Steam/Wine）、NVIDIA `nvidia-sync` 已安裝（用來連 DGX Spark）。2026-11-13 於自用桌機實測。
>
> 目標不是「讓 apt 安靜」，而是**消掉 notice 同時保留 i386 能力與 NVIDIA repo**。

---

## 0. 結論（先看這個）

三個 notice 是兩件事，不是三個 bug：

| # | notice | 機制 | 正確處理 |
|---|---|---|---|
| 1 | NodeSource `main/binary-i386/Packages` 跳過 | `i386` 是 foreign arch，但 NodeSource 只發布 amd64 | 對該 entry 加 `Architectures: amd64` |
| 2 | NVIDIA `proprietary/binary-i386/Packages` 跳過 | 同上，NVIDIA 只發布 amd64 | 同上 |
| 3 | `Missing Signed-By` | entry 是 `apt modernize-sources` 從舊 `.list` 轉出來的，轉換器把 `Signed-By:` 寫成**空值**，key 留在 `trusted.gpg.d` | 把 key 複製到 `/usr/share/keyrings/` 並填 `Signed-By` |

**不要**用 `dpkg --remove-architecture i386` 一次消掉前兩個——這台機器之後要裝 Steam/Wine 的
32-bit 依賴；**也不要**刪 NVIDIA repo——`nvidia-sync` 靠它更新，而它是連 DGX Spark 的工具。

---

## 1. 症狀

`sudo apt update` 尾巴固定三行（前面 12 個來源全部正常）：

```
Notice: Skipping acquire of configured file 'main/binary-i386/Packages' as repository 'https://deb.nodesource.com/node_24.x nodistro InRelease' doesn't support architecture 'i386'
Notice: Skipping acquire of configured file 'proprietary/binary-i386/Packages' as repository 'https://workbench.download.nvidia.com/stable/linux/debian default InRelease' doesn't support architecture 'i386'
Notice: Missing Signed-By in the sources.list(5) entry for 'https://workbench.download.nvidia.com/stable/linux/debian'
```

`apt dist-upgrade` 的「Not upgrading yet due to phasing」是另一件事（Ubuntu 分階段推送），與
notice 無關。

---

## 2. 先量測，再改（不要看到 notice 就動手）

| 量測 | 指令 | 結果 |
|---|---|---|
| 有哪些 foreign arch | `dpkg --print-foreign-architectures` | `i386` |
| 實際裝了幾個 i386 套件 | `dpkg-query -W -f='${Architecture}\n'` \| `grep -c i386` | **0** |
| 兩個 entry 長什麼樣 | `cat /etc/apt/sources.list.d/{nodesource,stable-linux-debian-default}.sources` | 兩者都沒有 `Architectures:`；NVIDIA 是 `Signed-By: `（空） |
| key 在哪、是哪把 | `gpg --show-keys /etc/apt/trusted.gpg.d/ai-workbench-desktop-key.asc` | `CD63F8B21266DE3C`，`svc-workbench@nvidia.com` |
| apt 實際想抓哪些索引 | `apt-get indextargets` | 兩個 repo 只有 amd64；Ubuntu archive 有 i386 |

關鍵推論：

- i386 是「開著但沒在用」——所以不能靠它存在與否來判斷，要看**是哪個 repo 沒有 i386 索引**。
- `Signed-By:` 是空字串而不是缺欄位，這是 `apt modernize-sources` 的已知轉換缺陷
  （Debian bug #1107140 同一形狀），不是使用者手誤。

---

## 3. 為什麼是「方案 B」：保留 i386，逐 repo 限制架構

`Architectures: amd64` 只作用在該 `.sources` 條目；Ubuntu 官方 archive 的 i386 索引照舊下載，
所以之後 `apt install steam-installer`、`wine32` 的 32-bit 依賴不受影響。

驗證「能力還在」的方法（修正後跑）：

```
$ dpkg --print-foreign-architectures
i386

$ apt-cache policy libc6:i386
  libc6:i386:
    已安裝：(無)
    候選： 2.43-2ubuntu2.7
       500 http://tw.archive.ubuntu.com/ubuntu resolute-updates/main i386 Packages
```

而 NVIDIA repo 不能刪，是因為它唯一被安裝的套件不是 AI Workbench：

| repo 內套件 | 版本數 | 狀態 |
|---|---|---|
| `nvidia-ai-workbench` | 10 | 未安裝 |
| `nvidia-sync` | 9 | **已安裝** `0.148.0~153-5805`（SSH tunnel 連 DGX Spark） |
| `nvidia-workbench` | 1（舊名 0.97.5） | 未安裝 |

`nvidia-sync` 只有 amd64 版；它跟 i386 notice 無關——那個 skip 是 apt 對「整個 repo」探測
`binary-i386/Packages` 時發出的，不是某個套件的問題。

---

## 4. 修正（逐條目，備份優先）

```bash
sudo cp -a /etc/apt/sources.list.d /etc/apt/sources.list.d.bak.$(date +%F)

# NVIDIA repo：key 搬到正式位置 + 填 Signed-By + 限制架構
sudo install -m 0644 /etc/apt/trusted.gpg.d/ai-workbench-desktop-key.asc \
                   /usr/share/keyrings/ai-workbench-desktop-key.asc
sudo sed -i -e '/^Components:/a Architectures: amd64' \
  -e 's|^Signed-By:.*|Signed-By: /usr/share/keyrings/ai-workbench-desktop-key.asc|' \
  /etc/apt/sources.list.d/stable-linux-debian-default.sources

# NodeSource：只限制架構
sudo sed -i '/^Components:/a Architectures: amd64' \
  /etc/apt/sources.list.d/nodesource.sources
```

實際 diff：

```diff
 Components: main
+Architectures: amd64
 Signed-By: /etc/apt/keyrings/nodesource.gpg

 Components: proprietary
-Signed-By:
+Architectures: amd64
+Signed-By: /usr/share/keyrings/ai-workbench-desktop-key.asc
```

可重複執行的版本：[`fix-apt-notices.sh`](fix-apt-notices.sh)（有 `grep -q '^Architectures:'`
守衛，重跑不會重複插欄位）。

---

## 5. 驗證（兩個都要做）

**(a) 在 tty 上跑真的 `apt-get update`** — 這是唯一能看到 notice 的方式：

```
Hit:1 … chrome-stable        Hit:7  … resolute-backports
Hit:2 … node_24.x            Hit:8  … resolute-security
Hit:3 … vscode               Hit:9  … esm-apps-security
Hit:4 … resolute             Hit:10 … esm-apps-updates
Hit:5 … resolute-updates     Hit:11 … esm-infra-security
Hit:6 … workbench nvidia     Hit:12 … esm-infra-updates
Notice/N:/W:/E: 行數 = 0     EXIT=0
```

**(b) 用全新的索引目錄強制重抓那兩個 repo** — 證明簽章是新路徑驗的，不是靠快取、也不是
靠 `trusted.gpg.d` 後備：

```
Get:1 … workbench … InRelease [7744 B]
Get:2 … workbench … amd64 Packages [4372 B]
Get:3 … node_24.x … InRelease [12.1 kB]
Get:4 … node_24.x … amd64 Packages [10.4 kB]
Reading package lists... Done
```

另外確認 `nvidia-sync` 候選版本仍是 `0.148.0~153-5805`（更新管道沒斷）。

---

## 6. 兩個坑

**6.1 `.asc` vs `.gpg`：apt 用副檔名判斷 key 格式**

照 NVIDIA 文件把 armored key 放成 `ai-workbench-desktop-key.gpg`，apt 直接拒收：

```
W: The key(s) in the keyring …ai-workbench-desktop-key.gpg are ignored as the file has an unsupported filetype.
W: OpenPGP signature verification failed … NO_PUBKEY CD63F8B21266DE3C
E: The repository … is not signed.
```

因為 apt 依副檔名決定「armored (.asc) / 二進位 (.gpg)」，不看內容。要嘛保留 `.asc`，要嘛
`gpg --dearmor` 轉二進位後再用 `.gpg`。

**6.2 notice 只在 tty 出現**

同一份設定、同一台機器：

- `apt-get update 2>&1 | tail` → **0 條**（連 `N:` 都沒有）
- `script -q -c "apt-get update" /dev/null` → 三條 `N:`

我一開始在 pipe 裡測，差點得出「已經沒有 notice」的錯誤結論。詳見
[playbook 0011](../../playbooks/0011-terminal-only-output-is-not-the-output.md)。

---

## 7. 誰來執行：agent 在沒有 sudo 密碼時的處理

這個 session 的 agent 是 uid 1000、`/etc` 屬 root、`sudo` 需要互動密碼（非互動時直接
`interactive authentication is required`），所以「自己 sudo」這條路不通。

在使用者於對話中**明確授權**「你來執行」之後，才用他在 `docker` 群組的權限（等於 root）以容器
進入 host chroot 完成修改，並且：

- 只動 3 個檔案（兩個 `.sources` + 一個 key 複本），沒有安裝/移除任何套件；
- 先 `cp -a` 備份整個 `sources.list.d`；
- 每一項都用「改完後重新下載索引」驗證，而不是只看檔案內容。

原則：**需要 root 的變更，只有在使用者明確授權時才走這條路；否則把指令交給使用者自己跑。**
把「agent 不能 sudo」誤判成「無法完成」也是不對的——先問權限，再問授權。

---

## 8. 可轉移的經驗

| 經驗 | 為什麼可轉移 |
|---|---|
| Notice 是「未來會壞」的佇列，不是錯誤 | exit code 與功能都正常；要判斷的是「誰需要被修」 |
| 多架構系統上，第三方 repo 的 i386 skip 要用 `Architectures:` 逐條目收斂 | 直接移除 foreign arch 會連 Steam/Wine 一起犧牲 |
| 刪 repo 前先查「誰在用」 | `apt-cache policy` 顯示真正被安裝的是 `nvidia-sync`，不是名稱裡的 AI Workbench |
| `Hit` 不代表簽章被重新驗證 | 要證明 `Signed-By` 生效，必須用全新 lists 目錄重抓 |
| 工具輸出會因 isatty 而不同 | 管線會吞掉 `Notice:`；量測終端，不要量測 pipeline |

---

## 9. 參考

- Debian bug #1107140 — `apt modernize-sources` 留空 `Signed-By`：<https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1107140>
- apt 2.9.24 NEWS — 沒寫 `Signed-By` 與 `trusted.gpg.d` 都被列為 deprecated（本機 `/usr/share/doc/apt/NEWS.Debian.gz`）
- Debian wiki SourcesList（`Signed-By` 用法）：<https://wiki.debian.org/SourcesList>
- NVIDIA 開發者論壇，同一把 key 的過期與更新：<https://forums.developer.nvidia.com/t/ubuntu-repo-signature-invalid-expkeysig-cd63f8b21266de3c-svc-workbench-svc-workbench-nvidia-com/354524>
- NVIDIA AI Workbench 桌面版安裝（官方 sources 寫法）：<https://docs.nvidia.com/ai-workbench/user-guide/latest/install/desktop-app-install.html>
