# Write-up：安裝 dsh-gitea 卻沒有可用工具 — 參數補齊、型別嚴格、重啟生效

- **日期**：2026-11-13（Asia/Taipei）
- **環境**：DSH web GUI（本機），profile `web`，外掛 `@goodandready/dsh-gitea` 0.7.44，Windows 10
- **目標連線**：自架 Forgejo 17.0.1（LAN 主机 `<LAN-IP>:3000`），open repos `829522/comfyui-gfx1151-rocm`（public、空）
- **英文摘要**：[`README.md`](README.md)；**可重用方法**：[playbook 0010](../../playbooks/0010-verify-a-plugin-we-can-call-its-tool.md)

## 背景

使用者先在本地 Forgejo 建立了 `comfyui-gfx1151-rocm` 空 repo，要求先用 DSH 檢查能否連線。
session 已有 `dsh-gitea` 外掛（profile bundle），因此第一步直接呼叫 `gitea_whoami` 等工具。

## 問題 1 — 所有 `gitea_*` 工具都回「Configure the Gitea instance URL in Settings.」

呼叫 `gitea_whoami` / `gitea_flavor` / `gitea_repo_search`，每一次都只回一行：

```
Configure the Gitea instance URL in Settings.
```

### 診斷

外掛 bundle 本身在 profile 的 `node_modules` 內有自己的 patch 插入節，內容是：

```yaml
- id: dsh-gitea
  config: {}
```

也就是「安裝」只註冊了一個 entry，**config 是空的**。沒有 `baseUrl` 時外掛沒有任何可用的
instance，所有工具就回這個固定錯誤。工具「存在」不代表「已連線」；必须从外部補 config。

### 兩個參數來源（各自獨立）

1. **凭据**：API 權杖不能 inline 寫进 patch。先在 DSH 凭据庫存一次，並以 env 风格名字引用：

   ```yaml
   # .credentials.yaml
   refs:
     <TOKEN-ENV>: <value>          # value 只存放於凭据庫，永不出现在笔记
   ```

   patch 裡只用 `tokenEnv: <TOKEN-ENV>` 指向它。

2. **profile 覆蓋**：把 `dsh-gitea` 的完整 config 寫到 profile 的 `cordis.patch.yml`（覆蓋檔，
   patchReload: live）：

   ```yaml
   - id: dsh-gitea
     config:
       baseUrl: http://<LAN-IP>:3000/
       tokenEnv: <TOKEN-ENV>
       defaultOwner: "829522"
       defaultRepo: comfyui-gfx1151-rocm
   ```

## 問題 2 — 設定寫好後，外掛反而「消失」

第一次 patch 寫入後重啟 DSH，結果**所有 `gitea_*` 工具消失**（`unknown tool`），不是錯誤而是
不存在。dsh-web log 裡有這行：

```
dsh-gitea (@goodandready/dsh-gitea): ValidationError: invalid config:
  - $.defaultOwner expected string but got 829522 (at defaultOwner)
```

### 原因

config 契約對 `baseUrl` / `tokenEnv` / `defaultOwner` / `defaultRepo` 都是 **string**。我第一次
寫的是：

```yaml
    defaultOwner: 829522        # ← YAML 未加引號 → 數字
```

YAML 未引號的數字被解析成 number → 嚴格型別檢查整個 entry 被拒絕 → 外掛連 load 都没有。
所以不是「工具报错」，而是「工具不存在」。

### 修法 — 加引號

```yaml
    defaultOwner: "829522"
```

後續原 API 驗證（`/api/v1/user`，`Authorization: token $env:<TOKEN-ENV>` → owner 829522、admin）
確認 `829522` 是正確的 login 值；問題純粹是型別。

## 問題 3 — patch 改完但不生效；重啟才生效

`cordis.patch.yml` 有 live patch reload，但**不會重新跑一個在 load 時已經失敗的外掛**。
覆蓋檔被改好後，工具仍未出現，直到整個 harness 重啟才重新載入外掛圖並生效。

- 在 session 內呼叫 `restart_harness` 會中止當前工具 call；這裡改用外部重啟 DSH web。
- 生效顺序：**修型別 → 重啟 harness → 再呼叫工具**。

## 驗證（重啟後）

| 工具 | 結果 |
|---|---|
| `gitea_whoami` | user 829522（admin） |
| `gitea_flavor` | Forgejo 17.0.1 OK |
| `gitea_repo_search` | 找到 `829522/comfyui-gfx1151-rocm`（public、空） |
| `gitea_issue_list` | 空 OK |
| `gitea_branches` | `[main]` OK |

權杖 end-to-end 驗證（權杖取自凭据 env，value 不輸出）：

```powershell
$base = 'http://<LAN-IP>:3000/api/v1'
$h = @{ Authorization = "token $env:<TOKEN-ENV>" }
Invoke-RestMethod "$base/user" -Headers $h   # → owner 829522
```

## 排查表（mental model）

| 現象 | 意義 | 下一步 |
|---|---|---|
| 所有 `gitea_*` 回「Configure the Gitea instance URL in Settings.」 | entry 存在、config 空 | 補 `baseUrl` / `tokenEnv` / `defaultOwner` / `defaultRepo` 覆蓋 |
| `gitea_*` 消失（`unknown tool`） | load 時 config 被拒絕 | 檢查各值型別（數字要加引號）、重啟 harness |
| 工具在、owner/repo 不對 | 覆蓋存在且已重啟 | 檢查 `defaultOwner` / `defaultRepo` 值与型別 |
| 工具在且正確 | 已 load | 開始實際工作（clone / issue flow） |

## 已套用的 SANITIZE

- `<LAN-IP>` 代替主机 IP；`C:\Users\<you>` 代替真实路径；權杖值與 `.credentials.yaml`
  contents 不复制进仓库；patch 只显示 env 引用形式。

## 可重用方法

→ [playbook 0010](../../playbooks/0010-verify-a-plugin-we-can-call-its-tool.md)
