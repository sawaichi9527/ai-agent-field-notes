# Write-up：`.credentials.yaml` 一個重複 key 讓整個 profile 起不來 — 錯誤只給位置，不給名字

- **日期**：2026-11-22（Asia/Taipei）
- **環境**：Windows 10 Enterprise LTSC，DSH CLI `@deepseek-ai/dsh` **0.2.2-rc.5**，npm **12.2.3**，profile `web`，外掛 `dshmarket` 1.77.0、第三方 `dsh-gitea`
- **英文摘要**：[`README.md`](README.md)；**可重用方法**：[playbook 0021](../../playbooks/0021-a-required-plugin-fails-on-its-data-file.md)、[playbook 0022](../../playbooks/0022-an-install-script-warning-is-not-a-missing-artifact.md)
- **探針**：[`tools/win/probe-store-duplicate-keys.ps1`](../../tools/win/probe-store-duplicate-keys.ps1)

## 背景

使用者透過 `dsh dshmarket` 把市場外掛更新到 1.77.0，重開機後執行 `dsh web`，啟動直接失敗。錯誤
訊息看起來像「外掛壞了」：一個 required 外掛沒啟用、12 個外掛在等 service。第一直覺是剛才的
更新造成的，於是重跑 `npm update -g @deepseek-ai/dsh` —— 完全一樣的錯誤，連行號都一樣。

真正的原因在**資料檔**，不在版本、不在外掛、也不在更新流程。

## 症狀

```
dsh: startup failed: 1 required plugin did not activate

Failed plugins (1):
  credentials
    Package: @deepseek-ai/dsh-credentials-local
    Error: credentials-local: invalid document at C:\Users\<you>\.dsh\.credentials.yaml:
           DUPLICATE_KEY at line 21, column 3

Plugins waiting for services (12):
  connection (required)  credentials
  authorization          credentials
  deepseek-account       credentials, authorization
  …
```

兩個容易誤判的地方：

1. **13 個外掛出事，其實只有一個問題。** `credentials` 是 required，它掛掉就中止整個啟動；
   其餘 12 個是 `inject: credentials` / `connection` 的**等待者**，不是 12 個獨立故障。
2. **錯誤不告訴你是哪個 key。** `DUPLICATE_KEY at line 21, column 3` 只有錯誤碼與位置 —— 因為
   YAML parser 原本的訊息會引用出錯的那一行，而這個檔案裡那一行就是 token 本人。DSH 刻意只保留
   code + line/col。所以「哪個 key 重複」必須自己算。

column 3 是關鍵線索：兩格縮排 = `refs:` 或 `records:` 的**直接子項**，也就是「重複的憑證名稱」
或「重複的 record id」，不會是更深層的欄位。

## 診斷

### 1. 這個檔案的合法形狀

```yaml
version: 1

refs:                      # 環境變數風格的名稱 → 值
  DEEPSEEK_API_KEY: sk-…
  GITEA_TOKEN: <token>

records:                   # <owner>/<id> → 帶型別的紀錄
  llm-pi-ai/openai-codex:
    kind: api-key
    env:
      X: y
```

`dsh-credentials-local` 以 `parseDocument(text, { uniqueKeys: true, prettyErrors: true })` 解析，
任何 parser 錯誤都轉成致命錯誤；`uniqueKeys: true` 讓重複 key 變成 `DUPLICATE_KEY`。
`refs` 的 key 必須是合法識別字，`records` 的 key 必須是 `<owner>/<id>`，值不得為空字串。

### 2. 用同一顆 parser 把重複的 key 找出來，且不印出值

不能直接 `Select-String "GITEA_TOKEN"` 之類的方式搜嗎？可以，但檔案裡有幾十個 token，人工比對
容易漏；而且**任何會把整行印出來的工具都可能把 secret 印到終端機或 log**。

所以探針的做法是：從已安裝的 dsh 目錄借同一份 `yaml`，用同一組選項解析，走 AST 收集每一層
mapping 的重複 key，只輸出**key 名稱 + 行/列**：

```
duplicate keys in C:\Users\<you>\.dsh\.credentials.yaml:

  "GITEA_TOKEN"  (in refs)
    first   line 19, column 3
    again   line 21, column 3
```

實作上是一個 PowerShell 外殼（`probe-store-duplicate-keys.ps1`）加一段 Node 核心：外殼把核心寫成
`%TEMP%` 下的暫存 `.mjs`，把子行程輸出**重導到檔案再讀回**（不經管線），結束後刪掉這兩個暫存檔。
條目目前標記為 `template` —— Node 核心已在四個輸入上驗證（重複、正常、tab 縮排、檔不存在），
PowerShell 外殼還要在 Windows 實機跑一次才能轉 `proven`。

實際檔案是這樣（第 20 行是空行或註解）：

```yaml
  GITEA_TOKEN: <token>      # line 19
                            # line 20
  GITEA_TOKEN: <token>      # line 21  ← 同一個值被貼了第二次
```

兩個都是可用的 token；使用者保留第一個、刪掉第二個。之後 `gitea_*` 工具正常，才確認留下的
那一個是對的 —— Gitea 的 token 只顯示一次，所以「哪個才是真的」要用呼叫驗證，不是用眼睛比對。

### 3. 被否證的假設

| 假設 | 為什麼看起來對 | 為什麼不對 |
|---|---|---|
| `dshmarket` 1.77.0 更新弄壞了 DSH | 時間點完全吻合（更新 + 重開機後立刻出現） | 錯誤指名的是**資料檔**；重裝／更新 dsh 後輸出完全相同，同行同列 |
| `npm update -g @deepseek-ai/dsh` 會修好 | 第一行 log 跟更新同一分鐘 | registry 的 `latest` 就是 0.2.2-rc.5，沒有新版可升；重跑後錯誤一字不差 |
| 重開機留下壞掉的檔案鎖 | 症狀從重開機後開始 | 該檔在每次啟動時讀取，失敗是確定性的 |
| token 本身失效 | 錯誤訊息裡出現 `GITEA_TOKEN` | 失敗發生在**解析階段**，還沒發出任何網路請求；token 失效會是 `gitea_whoami` 回 401 |

**可帶走的規則：更新後第二次出現一模一樣的錯誤，是證據，不是運氣不好。** 若錯誤內容（含行號）
不隨版本改變，那就不是版本問題。

## 修法

```powershell
# 1. 備份（純文字 secret，備份用完就刪）
copy "$env:USERPROFILE\.dsh\.credentials.yaml" "$env:USERPROFILE\.dsh\.credentials.yaml.bak"

# 2. 找出重複（不印值）
pwsh -File tools\win\probe-store-duplicate-keys.ps1 -Path "$env:USERPROFILE\.dsh\.credentials.yaml"

# 3. 刪掉重複的那一行，再驗一次
pwsh -File tools\win\probe-store-duplicate-keys.ps1 -Path "$env:USERPROFILE\.dsh\.credentials.yaml"   # → OK
dsh web
```

三個讓修改安全的規則：

- **刪除，不要清空。** 空字串會被拒絕（`""` 不等於「沒有這個 key」；移除 key 才是）。
  `records` 是多行結構（`kind:` + `payload:`），重複的 record 要整段刪。
- **留能用的那一個。** 兩個都像真 token 時，用一次 `gitea_whoami` 決定。
- **不用重開機、不用重裝。** 每次啟動都會重新讀這個檔；文件能解析，下一次 `dsh web` 就會過。
  注意啟動失敗與熱重載的語意不同：**熱重載**遇到壞檔會沿用上一份好的快照，**啟動**遇到壞檔
  則是直接失敗。

## 驗證

| 檢查 | 預期 |
|---|---|
| `probe-store-duplicate-keys.ps1 -Path …` | `OK`，沒有重複 key |
| `dsh web` | 進到 Web UI，沒有 `startup failed` |
| 外掛狀態 | 12 個等待中的外掛全部啟用；`dsh-gitea` 可呼叫 `gitea_whoami` |
| 終端機面板 `dir` | node-pty 正常 |

## 同一場 debug 的第二個問題：install-script 警告

整個過程每次 `npm install/update -g` 都會印：

```
npm warn install-scripts 4 packages had install scripts blocked because they are not covered by allowScripts:
npm warn install-scripts   koffi@3.1.1 (install: node ./cnoke.cjs -P . -D src/koffi --prebuild --release)
npm warn install-scripts   node-pty@1.2.0-beta.15 (install: node scripts/prebuild.js || node-gyp rebuild; postinstall: …)
npm warn install-scripts   @deepseek-ai/dsh-subprocess-local@0.2.2-rc.5 (postinstall: node scripts/ensure-spawn-helper.mjs)
npm warn install-scripts   pnpm@12.4.2 (preinstall: node install.js; postinstall: node install.js)
```

**這是政策提醒，不是缺原件。** 逐一核對安裝樹後，這四個套件沒有 script 也都能用：

- `koffi` 3.x 的原生二進位來自各平台的 optional dependency（`@koromix/koffi-<platform>`）；
  `cnoke` 是「從原始碼編譯」那條路。參考機上 `require('koffi')` 加真實呼叫可用，而 `cnoke` 從未跑過。
- `node-pty` 的 tarball 內**自帶** `prebuilds/win32-x64/conpty.node`；install script 只是 fallback。
- `dsh-subprocess-local` 的 postinstall 只對 POSIX 的 `spawn-helper` 補 `chmod +x`，Windows 上是 no-op。
- `pnpm` 的 `install.js` 屬於 pnpm 自己，跟 dsh 執行期無關。

另外，npm 建議的那條指令本身有陷阱：

```
npm install -g --allow-scripts=koffi,node-pty,@deepseek-ai/dsh-subprocess-local,pnpm
# → npm error path C:\Users\<you>\package.json  (ENOENT)
```

`npm install -g` 沒帶套件名時，npm 會把**目前目錄**當成要安裝的專案；使用者家目錄沒有
`package.json`，所以 ENOENT。要跑就得指名套件：

```
npm install -g @deepseek-ai/dsh --allow-scripts=koffi,node-pty,@deepseek-ai/dsh-subprocess-local,pnpm
```

而 `--allow-scripts` 是**單次**旗標，沒寫進 `.npmrc` 就每次重印警告；要持久化用
（注意這個設定是**整串覆蓋**，不是追加，舊的四個要一起列）：

```
npm config set allow-scripts=koffi,node-pty,@deepseek-ai/dsh-subprocess-local,pnpm,protobufjs,@google/genai --location=user
```

最後兩個（`protobufjs`、`@google/genai`）核對過原始碼也是無害：`@google/genai` 的 preinstall 是
`echo 'preinstall: no-op'`，`protobufjs` 的 postinstall 只比對 `versionScheme` 印一行提醒。

## 教訓

1. **required 外掛吃的是資料檔時，一行 YAML 就能癱掉整個 plugin graph。** 看到「N 個外掛等待
   service」先找那個 required 的根，不要一個一個查。
2. **錯誤只給位置是設計，不是缺陷。** 這個檔本身就是 secret，所以工具必須「只印 key 名稱與行列」。
   任何會 dump 整行的排錯腳本，對這個檔案都是洩漏風險。
3. **欄位位置可以反推結構。** column 3 = 兩格縮排 = `refs`/`records` 的直接子項；先縮小範圍再開檔，
   比整份檔案掃一遍快得多。
4. **更新後錯誤沒變，就別再更新。** 重跑 `npm update`、重開機、重裝都是同一個結論的複驗；真正
   的判準是「錯誤指名的檔案屬於誰」——屬於使用者資料的，版本永遠修不到。
5. **install-script 警告要先去確認「原件在不在」。** 有預編譯、有 per-platform optional dependency、
   或 script 本身是 POSIX-only 的 chmod，就不該為了消警告去開全域建置腳本。
