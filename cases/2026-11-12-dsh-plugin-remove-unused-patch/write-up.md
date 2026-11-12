# 案例：DSH 外掛「移除失敗」——真正卡住的是 pnpm 的過期補丁宣告

**工具／版本：** DSH `0.2.2-rc.1`（profile `web`）、pnpm `12.4.2`、Node `v24.21.0`
**外掛：** `dsh-multi-lang-ui` 0.1.1（GitHub git 依賴）
**系統：** Ubuntu 24.04.5 LTS　**日期：** 2026-11-12

## 症狀

一個早先安裝的 Web UI 多語系外掛，後來被另一個多語 bundle 取代，想把它移除。從 Plugin
Manager 按移除只得到一行：

```
Command failed with exit code 1: pnpm remove -w dsh-multi-lang-ui --reporter=ndjson
```

沒有其他訊息，重試也一樣。詭異的是：外掛清單裡看不到它，語言選項也沒它，但「已安裝」狀態
又陰魂不散。

## 先量測：錯誤被吞掉了

plugin-manager 每次操作都有自己的 log 目錄，但裡面**只有命令列**，沒有 pnpm 的 stderr：

```bash
ls -lat ~/.dsh/profiles/web/.plugin-manager/logs | head
cat ~/.dsh/profiles/web/.plugin-manager/logs/operation-*/pnpm.log
# => Command failed with exit code 1: pnpm remove -w dsh-multi-lang-ui '--reporter=ndjson'
```

所以第一步不是猜，而是**在 profile 的副本裡直接跑同一條 pnpm**，讓錯誤現形（副本跑壞了也
不影響正式環境）：

```bash
cp -a ~/.dsh/profiles/web ~/tmp/web-copy
cd ~/tmp/web-copy
pnpm remove -w dsh-multi-lang-ui --reporter=append-only
```

真正的錯誤：

```
Error: ERR_PNPM_UNUSED_PATCH
  × removing a package
  ╰─▶ The following patches were not used: dsh-multi-lang-ui@0.1.1
  help: Either remove them from "patchedDependencies" or update them to match
        packages in your dependencies.
```

## 兩個陷阱疊在一起

### 陷阱一：補丁活得比套件久

2026-10-05 為了讓這個外掛在 DSH 0.2.0-rc.2 上正常運作，曾用 pnpm 原生補丁機制修過它
（`patchedDependencies` + `patches/dsh-multi-lang-ui@0.1.1.patch`，lockfile 記 `patch_hash`）。
這是**外加在 profile 上的**，不是外掛或 dsh 管的。

pnpm 12 要求 `patchedDependencies` 裡的每個補丁都必須實際套用到某個依賴。一旦把唯一的
使用方移除，補丁就變成「未使用」——pnpm 不會順手清掉宣告，而是**中止整個 remove**：

```
ERR_PNPM_UNUSED_PATCH × removing a package
```

所以「移除失敗」其實是 pnpm 的保護機制，不是權限、不是鎖檔、也不是外掛壞掉。

### 陷阱二：先取消選取，才 remove

dsh 的 `removeBundle`（`@deepseek-ai/dsh-plugin-manager` 0.2.2-rc.1）流程是：

1. 把 bundle 從 `dsh.profile.bundles` 取消選取（立刻寫檔）
2. 才跑 `pnpm remove`

pnpm 一失敗，操作雖然回報失敗，但第 1 步已經落地。於是 profile 停在半完成狀態：

- `package.json` 依賴還在
- `node_modules/dsh-multi-lang-ui` 還在（其實仍安裝）
- `bundles` 清單已沒有它（所以不再載入）
- `cordis.patch.yml` 多了 `- id: multi-lang-ui` / `disabled: true` 的停用覆蓋

這就是「看起來移除了、重試卻永遠失敗」的來源：**看得見的狀態已經改了，看不見的狀態沒改**。

## 修復

```bash
# 0) 先備份（含補丁檔）
cd ~/.dsh/profiles/web
cp package.json pnpm-lock.yaml pnpm-workspace.yaml cordis.patch.yml ~/backup-20261112/
cp patches/dsh-multi-lang-ui@0.1.1.patch ~/backup-20261112/
```

```yaml
# 1) pnpm-workspace.yaml：刪掉這段（補丁已無使用方）
patchedDependencies:
  dsh-multi-lang-ui@0.1.1: patches/dsh-multi-lang-ui@0.1.1.patch
```

```bash
# 2) 重新移除（GUI 按鈕或 CLI 等價）
dsh plugin --profile web remove dsh-multi-lang-ui
# => dependencies:
#    - dsh-multi-lang-ui github:asd13006/dsh-multi-lang-ui
#    Done in 3s using pnpm v12.4.2
```

```bash
# 3) 清掉指向已刪格外掛的覆蓋列；否則組合時會警告
dsh --profile web --dump-config
# 修前：dsh: [.../cordis.patch.yml] patch: entry "multi-lang-ui" not found
```

```yaml
# cordis.patch.yml 尾端刪掉：
- id: multi-lang-ui
  disabled: true
```

```bash
# 4) 補丁檔已無任何引用，刪除（備份仍在）
rm patches/dsh-multi-lang-ui@0.1.1.patch && rmdir patches
```

## 驗證

| 驗證項 | 方法 | 結果 |
|---|---|---|
| 組合樹乾淨 | `dsh --profile web --dump-config` | stderr 0 bytes、202 個 row、無 `multi-lang` |
| 依賴清單 | `dsh plugin --profile web list --depth=0` | 6 個套件，無 `dsh-multi-lang-ui` |
| 檔案 | `node_modules/`、`pnpm-lock.yaml` | 目錄不存在；lock 0 筆引用 |
| 設定無殘留 | 搜尋 profile（排除 node_modules/log） | 0 筆引用，`patches/` 已移除 |
| 服務 | `GET http://127.0.0.1:3080/` | HTTP 401（未帶 token，屬正常的瀏覽器認證） |

移除由 HMR 即時套用（`application: applied`），不需要重啟：外掛本來就已取消選取，執行中的
行程從未持有它。

## 教訓

1. **「移除失敗」先找套件管理器的錯誤，不要只看 wrapper 的 exit code。** 包裝層（GUI／plugin
   manager）把 pnpm 的 stderr 吞掉了，真正的 `ERR_PNPM_UNUSED_PATCH` 只存在於自己重跑的輸出裡。
2. **「沒載入」不等於「已移除」。** 跨多個檔案的分段變更只要中途中止，就會留下前面幾步的結果。
   驗證時要同時看：依賴宣告、lockfile、`node_modules`、選取清單、覆蓋列。
3. **補丁宣告的擁有者要負責回收。** 為了舊版宿主加上的相容補丁，必須和套件一起移除；上游的
   「移除外掛」流程不會知道它的存在。
4. **失敗訊息只有 exit code 時，先去找該工具的操作 log**（如 `.plugin-manager/logs/operation-*/`），
   再在副本裡重跑原命令。

## 可回饋上游的改進

`plugin-manager` 的 `removeBundle` 可以：

1. 在 `pnpm remove` 前清掉 `pnpm-workspace.yaml` 中對應 `package@version` 的
   `patchedDependencies`（與 `patches/` 檔），讓 pnpm 不會因 `UNUSED_PATCH` 中止；
2. pnpm 失敗時回滾第 1 步的 bundle 取消選取，避免半完成狀態；
3. 把 pnpm 的 stderr 一併回傳到 GUI／工具結果，而不是只給 exit code。

## 回溯

```bash
# 回到移除前（半完成）狀態
cd ~/.dsh/profiles/web
cp ~/backup-20261112/{package.json,pnpm-lock.yaml,pnpm-workspace.yaml,cordis.patch.yml} .
mkdir -p patches && cp ~/backup-20261112/dsh-multi-lang-ui@0.1.1.patch patches/
pnpm install
```
