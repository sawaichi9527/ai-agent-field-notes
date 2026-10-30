> **Version caveat (added 2026-10-30).** These notes were taken on **dsh 0.1.5-rc.2**.
> One claim no longer holds on **0.2.1-rc.5**: "`patchReload: live` + Cordis HMR reloads the
> patch layer live, no restart needed". The key `patchReload` does not appear anywhere in the
> shipped 0.2.1-rc.5 code (including `.pnpm`), so it is vestigial. **Assume a restart is
> required** until you verify otherwise on your version.
> Everything else here (tool-plugin verification, package-name traps, patch-layer semantics,
> the marketplace's OBSERVED-beats-INFERRED rule) is still valid.
# `@maxhsu/dsh-forge`（俗稱 dsh-forgejo）安裝後在插件市場「已安裝」區不顯示

> 適用於另一台電腦的 DSH。2026-09-18 於本機實測驗證。
> 前置：dsh 0.1.5-rc.2（路徑與設定格式在相近版本應相同）

---

## 0. 先講結論（避免你查錯方向）

**「不顯示」不是安裝失敗。** 這個外掛是**純 host 側工具外掛**，沒有客戶端 UI：

| 事實 | 說明 |
|---|---|
| 會不會出現在外掛清單 | **不會有面板**。它的存在表現在「工具可用」 |
| 怎麼確認它活著 | **直接呼叫它註冊的 `forge_*` 工具**（見 §4） |
| 它提供什麼 | 11 個唯讀工具：`forge_instance_info`、`forge_list_repositories`、`forge_search_issues`、`forge_get_issue`、`forge_list_pull_requests`、`forge_get_pull_request`、`forge_get_pull_request_diff`、`forge_list_pull_request_files`、`forge_list_action_runs`、`forge_list_action_jobs`、`forge_get_action_job_logs` |

**真正會壞的是下一步**：profile 重建後，`baseUrl` / `token` 會是空的，工具一呼叫就報
`Set dsh-forge baseUrl or the DSH_FORGE_URL environment variable`。§3 是修法。

---

## 1. 名稱陷阱（先確認你裝對套件）

| 名稱 | npm 狀態 |
|---|---|
| `dsh-forgejo` | **HTTP 404 — 不存在**（用這個裝一定失敗） |
| `dsh-forgejo-plugin` | **404 — 不存在** |
| **`@maxhsu/dsh-forge`** | ✅ v0.3.3 —**正確套件** |
| `dsh-market` | 404（`dshmarket` 才是市場套件，無連字號） |

確認方法：

```powershell
node -e "fetch('https://registry.npmjs.org/@maxhsu/dsh-forge').then(r=>console.log(r.status))"
# 200 = 存在；404 = 名稱錯
```

---

## 2. 安裝（若還沒裝）

### 方式 A：走插件市場（建議）

在 dshmarket UI 搜尋 Forgejo / 作者 Max Hsu，安裝 `@maxhsu/dsh-forge`。
市場安裝成功後**會自動排程重啟**（`dshmarket` 內建 `lib/restart.js`），
你可以從它的日誌確認：

```
<profile>\.dsh-market\log.ndjson
{"event":"install","detail":"@maxhsu/dsh-forge exit=0 hot=false"}
{"event":"restart","detail":"scheduled pid=... helper=..."}
```

`hot=false` 代表需要重啟才會生效，市場已幫你排程。

### 方式 B：命令列

```powershell
dsh plugin --profile web add @maxhsu/dsh-forge
```

> **警告**：`dsh plugin` 只在 pnpm **exit 0** 時才會更新 `bundles`。
> 若 pnpm 因 `ERR_PNPM_IGNORED_BUILDS` 而 exit 1，套件裝好了但外掛**不會**生效。
> 這種情況先在 `pnpm-workspace.yaml` 加：
> ```yaml
> allowBuilds:
>   <pnpm 印出的套件名>: true
> ```
> 再重跑同一指令。

---

## 3. 【核心修法】補上連線設定

外掛本身**沒有任何內建設定**，必須由 config 傳入。設定寫在 **profile 的 patch 層**：

**檔案位置**

```
C:\Users\<你>\.dsh\profiles\web\cordis.patch.yml
```

（macOS / Linux：`~/.dsh/profiles/web/cordis.patch.yml`）

**內容**（把原本的 `[]` 換成下面這段）

```yaml
- id: forge-tools
  name: '@maxhsu/dsh-forge'
  config:
    baseUrl: 'http://<你的 Forgejo 主機>:3000'
    token: '<read-only token>'
    locale: zh-TW
    requestTimeoutMs: 30000
    maxResponseBytes: 1000000
```

**四個必須知道的細節**

1. **`config` 是整個物件取代，不是合併。** 五個鍵都要寫，漏掉的會變 undefined。
   這五個正是外掛自己 `cordis.patch.yml` 的預設值，照抄即可。
2. **`id` 必須是 `forge-tools`**（不是套件名）。這是外掛 patch 裡定義的 entry id。
3. **`name` 必須完全等於 `'@maxhsu/dsh-forge'`**（含 `@` 與引號）。
   patch 的 `name` 若與目標不符，會被**警告並跳過**，設定不會生效。
4. **不用重啟。** profile 是 `patchReload: live`，Cordis HMR 會監看
   `cordis.patch.yml`，存檔後設定即時生效。

> **token 權限提醒**：`dsh-forge` 全部 11 個工具都是**唯讀**，用 read-only token 就夠。
> 不要沿用有 admin/push 權限的 token。token 會以**明文**存在這個檔案裡；
> 若不想落地，改用環境變數 `DSH_FORGE_URL` / `DSH_FORGE_TOKEN` 並把這兩個欄位留空。

---

## 4. 【驗證】怎麼確認真的通了

### 步驟 1：確認設定被套用

```powershell
dsh --profile web --dump-config 2>&1 | Select-String "dsh-forge" -Context 0,8
```

**成功長這樣**（注意 `patched by` 那行，以及 baseUrl 已填入）：

```
# == @maxhsu/dsh-forge, patched by C:\...\profiles\web\cordis.patch.yml
- id: forge-tools
  name: '@maxhsu/dsh-forge'
  config:
    baseUrl: http://192.168.x.x:3000
    ...
```

若出現 `entry "forge-tools" not found` 或 `name mismatch` → §3 的細節 2 / 3 寫錯了。

### 步驟 2：確認外掛有載入

```powershell
Get-ChildItem "$env:USERPROFILE\.dsh\profiles\web\node_modules\@maxhsu\dsh-forge" |
  Select-Object Name
Get-Content "$env:USERPROFILE\.dsh\profiles\web\package.json" -Raw
```

`package.json` 的 `dsh.profile.bundles` 應該含有 `@maxhsu/dsh-forge`。

### 步驟 3：**決定性測試** — 直接呼叫工具

在 dsh 對話裡請模型呼叫 `forge_instance_info`，或在模型選擇器選任一可用模型後下這個指令。

| 回應 | 意義 | 處理 |
|---|---|---|
| `{"version": "16.0.4+gitea-1.22.0"}` 之類 | ✅ **完全正常** | 完成 |
| `Error: Set dsh-forge baseUrl or the DSH_FORGE_URL environment variable` | 外掛有載入，但 config 是空的 | 回去做 §3 |
| `unknown tool` / 工具不存在 | 外掛沒載入 | 檢查 §2 的 `bundles` 是否更新；重啟 dsh |

> **這就是判斷「它到底活著沒」的唯一可靠方法。** 不要看 UI 有沒有面板。

---

## 5. 為什麼市場「已安裝」區看起來不對

`dshmarket` 判定一個套件狀態的邏輯（`lib/verify.js` → `verifyActivation`）：

```
state = live    ← Loader 實際正在跑（ground truth，優先於任何 manifest 推論）
      | missing | disabled | broken | restart | ...
```

判定順序大致是：

1. `node_modules/<name>` 不存在 → `missing`
2. 被市場停用清單或 patch 層停用 → `disabled`（重啟也保持關閉）
3. **`loaderLive`** → `live`（**以 Loader 實際狀態為準，不是看 package.json**）
4. 沒有 `dsh` metadata 且沒被載入 → `broken` / `restart` / 一般相依套件

**重點**：`verify.js` 的註解明寫 *OBSERVED beats INFERRED* —
「loader inventory is ground truth」。所以：

- 只要 Loader 有跑它，市場就該顯示為 live
- 若顯示 `restart`，代表「已列入 bundle 但還沒重啟生效」
- **市場的「已安裝」區是市場自己的 UI 判斷，與外掛有沒有客戶端面板是兩件事**

因此若你遇到的症狀是「市場已安裝區看不到」，可能原因依序排查：

1. **還沒重啟** → 看 `log.ndjson` 有沒有 `hot=false` + `scheduled`；手動 `dsh web` 重啟一次
2. **bundle 未更新** → 檢查 `package.json` 是否有 `@maxhsu/dsh-forge`（見 §2 的 exit code 警告）
3. **市場 UI 的顯示口徑** → 到 **Settings → Plugins** 的完整清單找 `@maxhsu/dsh-forge`，
   它會以 **entry id `forge-tools`** 出現，**不是** `dsh-forgejo`
4. **名稱認知落差** → 你在找 `dsh-forgejo`，清單裡顯示的是 `@maxhsu/dsh-forge`

> **不要**因為「看不到」就砍 `profiles/web` 重來。那個目錄是整個 profile 的家
> （外掛清單 + 載入順序 + node_modules + 你自己的設定），砍掉會讓**所有**外掛與設定消失，
> 且 dsh 會重建一個空骨架，症狀會更難查。要移除外掛用：
> ```powershell
> dsh plugin --profile web remove <套件名>
> ```

---

## 6. 一頁式檢查清單

```
[ ] 1. 套件名是 @maxhsu/dsh-forge（不是 dsh-forgejo）
[ ] 2. node_modules\@maxhsu\dsh-forge 存在
[ ] 3. profile 的 package.json → dsh.profile.bundles 含 @maxhsu/dsh-forge
[ ] 4. 安裝後有重啟 dsh web（市場會自動排程，或手動）
[ ] 5. cordis.patch.yml 有 id: forge-tools 的 patch，config 五個鍵齊全
[ ] 6. dsh --dump-config 顯示 "patched by ...cordis.patch.yml"
[ ] 7. 呼叫 forge_instance_info 有回應（不是 baseUrl 錯誤、不是 unknown tool）
```

第 6 和第 7 項都通過 = 完全正常，即使市場 UI 看起來「怪怪的」也不用管。

---

## 7. 出處

本文件內容來自 2026-09-18 本機實際除錯，證據包括：

- `@maxhsu/dsh-forge@0.3.3` 實體檢查（`lib/client.js` 是 REST client 非 UI bundle；
  `lib/index.js` 的 `inject = ['tools']`；`cordis.patch.yml` 只有 `insert: forge-tools`）
- 從 profile 目錄載入模組並實際呼叫 `apply()`，確認註冊 11 個 `forge_*` 工具
- `dsh --profile web --dump-config` 前後對照（patch 套用成功且無警告）
- 實際呼叫 `forge_instance_info` 得到 `{"version": "16.0.4+gitea-1.22.0"}`
- `dshmarket/lib/verify.js` 的狀態判定邏輯、`lib/restart.js` 的自動重啟機制、
  `.dsh-market/log.ndjson` 的安裝與重啟紀錄
