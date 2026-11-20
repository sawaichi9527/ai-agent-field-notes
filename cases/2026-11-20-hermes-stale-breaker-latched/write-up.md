# hermes-agent：整個 session 被自己的重試記帳鎖死——stale timeout 量到的是「排隊位置」，不是模型速度

> 環境：Ubuntu（kernel 7.0）· AMD Ryzen AI MAX+ 395 / Radeon 8060S · hermes-agent v0.23.2
> （9 profiles multi-profile gateway）· 本地 `ornith-1.5-35b-a3b` Q4_K_M via LM Studio @
> `<LAN-IP>:1234`（單一請求槽、262144 ctx）· 2026-11-20 晚間。
>
> 前情：同一台後端的「後端沉默但心跳正常」在
> [`../2026-11-18-coordinator-hung-worker-local-decode-stall/`](../2026-11-18-coordinator-hung-worker-local-decode-stall/)
> 被處理過（那把 `local_stream_stale_timeout` 由 900 降到 300）。本篇是同一個旋鈕往反方向轉，
> 而且量到了它的真正上限。

---

## 0. 結論（30 秒）

| 檢查 | 結果 |
|---|---|
| 使用者送訊息後多久回？ | **0.5 秒**（等於沒送出去） |
| 有沒有打到模型？ | **沒有** — `request_dump` 記 `non_retryable_client_error`，連線都沒開 |
| 模型那時活著嗎？ | 活著 — 同一個 endpoint 直接發 16-token 請求 **0.29 s** 回 200 |
| 為什麼拒絕？ | 跨回合熔斷器 `_consecutive_stale_streams` 累到 **6**（門檻 5）→ 之後每次呼叫**先拋錯** |
| 為什麼會被 stale？ | `local_stream_stale_timeout: 300` 低於「排一個別人的請求」所需的 TTFT（實測 **400.8 s**） |
| 300 秒對單一請求夠嗎？ | **夠** — 單獨一筆 98k 冷請求 TTFT 只有 **195.5 s** |
| 這個旋鈕量的是什麼？ | **TTFT 預算**（每個 chunk 會歸零），不是總時長、也不是輸出長度 |
| 修法 | 全部 profile 300 → **900**；重啟清熔斷（值本身熱載入，不需要重啟） |
| 代價 | 真正卡死的後端現在要 900s × 3 次嘗試 ≈ **45 分鐘**才放棄，5 次才熔斷 ≈ 75 分鐘 |

真正的結論不是「900 夠」，而是：**這個 timeout 是在猜排隊位置，而排隊位置由「幾個 agent 共用
一個單槽後端」決定；7 個 profile 指著同一台，任何固定值都只是把爆點往後推。**

---

## 1. 症狀：看起來像「不理我」，其實是「連試都不試」

Lark/Feishu 那一側收到的是這樣：

```
❌ custom rejected the request and retrying won't help:
Provider has been unresponsive (no response received) for 6 consecutive stale attempts —
aborting this call to avoid an indefinite stall. Switch models or start a new session, then retry.
```

使用者的描述是「hermes 不再響應我的回覆」。這很容易被讀成「模型掛了」或「網路斷了」，但兩個
細節指向相反方向：

1. 那句 `retrying won't help` 是 Hermes 自己的字，不是 provider 的錯誤；
2. 回覆時間 **0.5 秒** —— 比任何一次正常回覆都快兩個數量級。

`errors.log` 對照得很清楚：

```
19:08:18 API call failed (attempt 1/3, not retryable) … 6 consecutive stale attempts
19:08:18 response ready: platform=feishu … time=0.5s api_calls=1 response=359 chars
19:17:58 API call failed (attempt 1/3, not retryable) … 6 consecutive stale attempts   # msg='停止'，2 字
```

兩則訊息（17 字、2 字）都是同一個 0.5 秒、同一個 `api_calls=1`。也就是說：**每一次呼叫都在
送出前就被拒絕**，而它拒絕的理由是「過去六次都沒回應」。

（附帶：`response=359 chars` 就是使用者貼給我看的那段錯誤文字。使用者看到的是「hermes 在回我」，
實際上是 client 在自言自語。）

---

## 2. 第一個直覺（錯的）：把它當成「模型太慢」

第一輪的推理是：300 秒太短，本地模型在 9.8 萬 token 的 context 下要幾分鐘，所以被砍成 stale；
那就把 300 改成 900。這個結論**剛好是對的修法**，但**理由是錯的**，而且錯得很危險 —— 它會讓人
以為「900 就解決了」。

錯在哪裡：

- 日誌裡單獨一筆 `in=94,824 / out=3,100` 的呼叫只花 **292 秒**，離 300 還有 8 秒 —— 這種「剛好
  擦邊」看起來很像「模型太慢」，但它同時也說明 **單請求根本沒超過 300**。
- 真正超過 300 的那些，`chunks=0`、`bytes=0`、`elapsed=300.0x` —— 連一個 byte 都沒收到。
- 於是出現了兩個互斥的解釋：要嘛 prefill 真的超過 300 秒（那 292 秒那次怎麼活的？），要嘛
  這台後端在「開始算之前」就讓請求等了 300 秒。**必須量，不能猜。**

---

## 3. 量測設計：三個控制組，一個對照

探針：[`tools/linux/probe-ttft-under-contention.py`](../../tools/linux/probe-ttft-under-contention.py)
（stdlib only；用 SSE 逐行讀，分別記 `ttfb`（拿到 header）與 `first_token`（第一個 delta 到達））。

設計上刻意做了四件事，缺一件結論就會歪：

| 設計 | 目的 |
|---|---|
| prompt 開頭塞 **600 個隨機 salt 字串** | 破壞 prompt cache，確保是「冷」請求 |
| 同一個 payload 跑第二次 | **對照組**：若第二次瞬間回來，證明第一次量到的真的是 prefill |
| 另外做一份 ~50k 的冷請求 | 看 prefill 是否隨長度惡化（非線性？） |
| 兩個 ~100k 冷請求**同時**送出 | 直接量「排隊」，而不是推論排隊 |

每個請求只要求 `max_tokens: 16`，讓 TTFT 主導總時間；`stream_options.include_usage` 取回真實
`prompt_tokens`（不是自己用字數估的 —— 估算值 98k 實際是 **117k**，差 20%）。

### 3.1 量到的數字

| 情境 | prompt tokens | TTFT | 有效 prefill |
|---|---|---|---|
| 冷、單獨 | 117,146 | **195.5 s** | 599 tok/s |
| 同一個 prompt 再跑（cache 命中） | 117,146 | **0.25 s** | — |
| 冷、單獨 | 59,669 | **69.4 s** | 860 tok/s |
| 冷、排在另一個 100k 後面 | 115,651 | **400.8 s** | 289 tok/s（含等待） |

decode 全程 **28.9–36.7 tok/s**。

### 3.2 三個可以直接讀出來的結論

**(a) 單一 98k 冷請求 = 195 秒，300 秒是夠的。**
所以「模型太慢」不是這次爆炸的原因。它只是**接近**上限，讓下一次多一個請求就翻車。

**(b) 第二個請求 = 400.8 秒 ≈ 195 + 195，嚴格序列化。**
這台 llama.cpp/LM Studio 是**一個請求槽**：沒有 continuous batching、沒有平行。第二個請求要等
第一個「完整跑完」（含 decode）才開始 prefill。實測的 400.8 秒裡沒有任何「一起算」的跡象。

**(c) prompt cache 是 780 倍速差（0.25 s vs 195 s）。**
同一個 session 連續回合共用 prefix，所以日誌裡會看到「59k input、6 秒完成」和「98k input、300 秒
被砍」並存 —— 變動的不是模型，是 cache 與佇列。任何只看 token 數的推論都會在這一步出錯。

**(d) 順帶：prefill 不是線性的。** 60k → 860 tok/s，117k → 599 tok/s。所以「98k 大約是 60k 的
兩倍時間」是低估，實際上 195/69 ≈ 2.8 倍。

---

## 4. 兩個機制，缺一不可

到此為止只解釋了「為什麼會被砍」。但「為什麼之後永遠不理人」是**另一個**機制。

### 4.1 熔斷器：把「慢」變成「永久拒絕」

`agent/chat_completion_helpers.py`：

```python
def _bump_stale_streak(agent):
    agent._consecutive_stale_streams = _stale_streak(agent) + 1

def _check_stale_giveup(agent):
    if _giveup > 0 and _streak >= _giveup:      # HERMES_STREAM_STALE_GIVEUP，預設 5
        raise RuntimeError("Provider has been unresponsive … aborting this call …")
```

- 每次 stale kill → streak +1；
- streak 只在**呼叫成功**、**切換模型/provider**（`/model`、fallback）、或**行程重啟**時歸零；
- 它是 `agent` 物件上的**記憶體屬性** —— 不進 session store、不進 DB。

所以第 6 次之後，`_check_stale_giveup` 在**任何網路動作之前**就拋錯。這就是 0.5 秒回覆的來源，
也是「重試永遠沒用」的來源：重試只會再一次撞到同一道牆。

**這是本 case 最值得記住的一件事：一個用來「避免無限等待」的機制，在慢後端上會把「很慢」
升級成「完全不能用」，而使用者看到的是後者。**

### 4.2 stale 計時器量的到底是什麼

`agent/chat_completion_stream_monitor.py` 的看門狗每 0.3 秒比一次：

```python
_stale_elapsed = time.time() - self.last_chunk_time["t"]
if _stale_elapsed > self._stream_stale_timeout:
    self._kill_stale_stream(_stale_elapsed)
```

而 `last_chunk_time` 在**每一個真實 chunk** 都會被重設（`_count_chunk`）。推論：

- 它**不是**請求總時長的上限；
- 它**不是**輸出長度的上限（decode 時 chunk 每幾十毫秒來一次）；
- 它**只**量「多久沒有收到任何東西」，實務上就是 **TTFT**（加上中途斷流的間隔）。

我用保留的日誌驗證了這一點 —— 所有 stale kill 依 `chunks` 分布：

| chunks | kills |
|---|---|
| **0** | **188** |
| 45 – 4011 | 13 |

**93.5% 的 stale 是「一個 byte 都沒收到」**，不是「跑到一半停住」。所以這個旋鈕在這種後端上
實際上是「TTFT 上限」。想用「輸出很長所以需要更大 timeout」來解釋它，是方向錯誤。

---

## 5. 修法與驗證

1. `agent.local_stream_stale_timeout`：300 → **900**，套用到所有指向本地後端的 profile。
   - **每個 named profile 只讀自己的 `~/.hermes/profiles/<name>/config.yaml`，不合併全域檔**
     （11-18 已量過；這次再次以 loader 驗證）。
2. 清熔斷：重啟 gateway（或 `/model` 切兩次）。**重啟是為了清 streak，不是為了讓新值生效** ——
   `load_config_readonly()` 以檔案 mtime 失效快取，下一個請求就吃到新值。
3. 驗證用 Hermes 自己的 loader 逐 profile 讀，而不是 grep 檔案：

```
$ HERMES_HOME=…/profiles/<name> python -c \
    "from hermes_cli.config import load_config_readonly; c=load_config_readonly(); print((c['agent'])['local_stream_stale_timeout'])"
900     # × 7 個本地 profile；遠端 .215 與雲端 opencode 亦為 900（未牽涉本次事故）
```

4. 事件後行為：同一個 session 的下一次對話正常完成（`in=17,062 / out=432 / 21.0s`），
   先前的錯誤訊息也沒有把對話內容弄壞（gateway 會 persist 失敗的 user turn）。

### 5.1 900 的意義（可推導，不是預設值）

用 3.1 的表：單一冷 100k 請求 TTFT ≈ 195 秒，且嚴格序列化。所以

| 同時有 n 個 100k 冷請求 | 最壞 TTFT | 300 s | 900 s |
|---|---|---|---|
| 1 | ~195 s | 勉強 | ✅ |
| 2 | ~400 s | ❌ | ✅ |
| 3 | ~600 s | ❌ | ✅ |
| 4 | ~800 s | ❌ | ✅ |
| ≥5 | >1000 s | ❌ | ❌ |

**900 覆蓋到 4 個並發。** 會得到 900 這個數字，是因為它是上游對本地 provider 的預設；但「它
到底買到多少」是上表算出來的 —— 而這台機器有 **7 個 profile** 指著同一個單槽後端，所以 900
不是免疫，只是把爆點從 2 推到 5。

---

## 6. 這個修法重新打開了什麼（誠實記錄）

11-18 那把 900 → 300 是**有理由的**：後端真的卡死時（HTTP 200、零輸出、心跳照跳），kanban 的
stale 偵測（3600 秒無心跳）看不到它，只能靠 client 端的 stale 把它踢掉。

改回 900 的代價，明確寫下來：

- 死掉的後端：**900 s × 最多 3 次嘗試 ≈ 45 分鐘** 才會讓一次 API call 失敗；
- 要累到熔斷（5 次）：**≈ 75 分鐘**。

也就是說，這次修復用「排隊時不再誤殺」換掉了「卡死時快速回收」。真正能兩者兼得的做法：

1. **不要讓 7 個 agent 共用一個單槽後端** —— 排隊等待原則上是無界的，任何 timeout 都只是猜；
2. **壓 context**：98k → 20–30k，冷 TTFT 從 195 秒掉到 ~25 秒，300 秒都夠；
3. **對話走雲端 fallback**，本地留可中斷的批次工作；
4. 真要防「一直有 chunk 但永遠不結束」，用 `agent.stream_max_lifetime`（per-chunk 重置抓不到）。

---

## 7. 可重現的最小步驟

```bash
# 1. 冷請求 TTFT（破壞 cache：payload 內含隨機 salt）
TTFT_BASE_URL=http://<LAN-IP>:1234/v1 TTFT_API_KEY=… \
  tools/linux/probe-ttft-under-contention.py --model ornith-1.5-35b-a3b --tokens 117000

# 2. 對照組：同一個 payload 再跑一次（應 <1s）
TTFT_BASE_URL=… tools/linux/probe-ttft-under-contention.py --model … --tokens 117000 --warm

# 3. 排隊：兩個同時送
TTFT_BASE_URL=… tools/linux/probe-ttft-under-contention.py --model … --tokens 117000 --concurrency 2
```

判讀規則：`--concurrency 2` 的**第二筆** TTFT ≈ 兩倍單筆 → 單槽序列化；若接近單筆 → 有平行，
那 timeout 的算法要換。

---

## 8. 被推翻的假設（完整表）

| 假設 | 測試 | 結果 |
|---|---|---|
| provider 掛了／模型被卸載 | 事故當下對同一 endpoint 發 16-token 請求 | **推翻**：0.29 s、HTTP 200 |
| 模型在大 context 下太慢，所以調大 timeout | 量 60k 與 117k 的冷 TTFT | **部分推翻**：單請求 195 s < 300 s；需要的是「排隊」這個變數 |
| 與 11-18 是同一個 bug | 比對 signature | **機制不同、表徵相同**：那時是引擎卡死（900 s、context 凍結、心跳正常）；這次是等單槽，重試會好 |
| stale 計時器是「請求總長上限」 | 讀 monitor 迴圈 + chunk 分布 | **推翻**：每個 chunk 歸零；188/201 次是零 chunk |
| 改 config 需要重啟才生效 | 改完用 loader 讀 | **推翻**：mtime 失效；重啟只為清熔斷 |
| 熔斷計數會寫進 session 持久化 | 找資料流 | **推翻**：純記憶體屬性，重啟即清零 |

---

## 9. 可轉移的一課

> **Timeout 是一個關於「排隊位置」的聲明，不是關於「模型速度」的聲明。**

同一個數值，對第一個請求是綽綽有餘，對第二個請求是腰斬 —— 而在 client 端完全看不出來，因為
兩個請求的日誌長得一模一樣（`HTTP 200`、`chunks=0`、`ttfb=-`）。要分辨它們，只能從外面量：
先量單獨的 TTFT，再量「有人在前面」的 TTFT，兩者的差就是單槽後端的排隊成本。

而當 retry 預算 + 熔斷器存在時，這個算術會升級成**永久性故障**：慢 → stale → retry → stale →
熔斷 → 之後連試都不試。使用者看到的「不理我」其實是「它已經放棄了」。方法論見
[playbook 0019](../../playbooks/0019-a-timeout-measures-queue-position.md)；
同族的「liveness ≠ progress」見 [playbook 0015](../../playbooks/0015-stale-watchdog-is-a-timing-claim.md)。
