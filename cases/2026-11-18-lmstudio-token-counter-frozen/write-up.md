# LM Studio 停在「125 tok」：引擎其實已經生了 15.9 萬個 token

> 2026-11-18 · LM Studio 0.4.x（內建 llama.cpp，MTP 開啟）· `ornith-1.5-35b-a3b@q4_k_m`
> · Ryzen AI MAX+ 395 / Radeon 8060S、128 GB 統一記憶體 · Ubuntu（kernel 7.0.0-43-generic）

## 1. 症狀

「Loaded Models」卡片連續一小時顯示：

```
1032  GEN  (+2 QUEUED)  125 tok   ⟳
```

轉圈動畫沒停、數字沒動、後面還有兩個請求在排隊。卡片上有 **MTP** 標籤，context 262144、
GPU 卸載 41 層、Unified KV Cache 與 Context Checkpoints 都開著——所有「本地推論卡死」的
常見嫌疑都到齊了，所以第一個判斷是「引擎卡住」。

**這個判斷是錯的。**

## 2. 先看引擎自己的計數器

LM Studio 的 server log 在 `~/.lmstudio/server-logs/<yyyy-mm>/<date>.<n>.log`。同一個請求
（`chatcmpl-wng92wkrofqpthzgrc7krg`）的紀錄：

| 時間 | 事件 | 數字 |
|---|---|---|
| 17:43:27 | 請求進來（6 messages） | prompt **6104** tok、prefill 1196 t/s |
| 17:43:34 | 第一個 packet | — |
| **18:30:03** | **截圖那一刻** | **n_gen = 126,659** |
| 18:45:42 | 最後一筆執行中樣本 | **n_gen = 159,261**、`tg = 42.72 t/s` |
| 18:45:50 | `Model unloaded by user or API request` | 生成結束 |

`slot print_timing` 每 3 秒印一次，連續 **62 分鐘**，`tg` 從 60 平滑降到 42 t/s（context 越長
越慢）。也就是說螢幕顯示 125 的時候，引擎已經吐了 12.6 萬個 token。

```
[2026-11-18 18:30:03][DEBUG] ... I slot print_timing: id 0 | task 525753 |
    n_gen = 126659, tg = 45.41 t/s, tg_3s = 36.53 t/s
```

## 3. 「125」是什麼算出來的

把 SSE packet 還原後，這條回應只有三種 delta：

```
delta keys        {'role': 1, 'reasoning_content': 110, 'content': 15, 'tool_calls': 23272}
text chunks       reasoning=110 content=15 -> 125
finish_reasons    none
```

**110 + 15 = 125**，跟卡片上的數字一模一樣。也就是說 UI 的 `tok` 只累計 reasoning/content
這兩種「文字」chunk，`tool_calls` 的 23,272 個 chunk 完全不算。模型從第 125 個 chunk 之後
就只產 tool_call 片段，所以數字凍住——但引擎還在跑。

`tok` 從來不是「生成進度」，是「這則訊息裡會被當文字渲染的部分」。

## 4. 模型卡在 tool call 的 JSON 裡

`tool_call[0]`（`web_extract`，三個網址）正常結束。`tool_call[1]`（`web_search`）沒有：

```json
{"query":"","limit":6,"limit":6,"limit":6, ... }
```

`,"limit":6` 重複了約 10,500 次、共 115,891 字元，**沒有收尾的 `}`，`finish_reason` 從未出現**。
這是典型的退化重複（degenerate repetition）：產出的是一個合法的 JSON *前綴*，所以沒有東西
會拒絕它；而 llama.cpp 的 tool-call 串流不會強迫物件收尾，模型就一直補同一個 key。

為什麼是一小時：

| 因素 | 值 | 效果 |
|---|---|---|
| 該請求的 `max_tokens` | **沒有帶** | 沒有任何上限 |
| context | 262144 | 以 42 t/s 還有約 100 分鐘可跑，估計 19:2x 才會撞上限 |
| 上層 agent 重試 | 每 ~15 分鐘送 12-message / 67-message 請求 | 全部排在後面 → `+2 QUEUED` |

上層 harness 用計時器重試，但沒有先取消前一個請求；於是佇列越堆越深，而 queue depth
在「頭永遠不會完成」的情況下不是背壓。

## 5. 被推翻的假設（含我自己一開始的判斷）

| 假設 | 檢查 | 結果 |
|---|---|---|
| MTP / speculative decoding 的 bug | grep `inconsistent sequence positions`、`failed to process speculative batch` | **0 筆**。lmstudio#2160 的 124-token 簽章是另一種失敗（draft batch 被拒、slot 被釋放） |
| 記憶體爆掉 / swap | 執行中 `free -h` | 121 GiB 用 41 GiB、**swap 31 GiB 用 0** |
| 伺服器崩潰 / 佇列死鎖 | `curl http://<LAN-IP>:1234/api/v0/models` | 有 HTTP 回應（401 要 token）——伺服器一小時都活著 |
| GPU / Metal 停住 | 整小時的 `tg` | 60 → 42 t/s 平滑下降，沒有平線 |

第一個假設是「只看截圖」最容易得到的結論，也是錯的。截圖分不出「引擎閒著」和「引擎在忙、
顯示沒更新」；log 可以。

## 6. 事後處置

1. **每個請求都帶 `max_tokens`**（tool-calling agent 用 4k–8k）。同一份 log 裡後來的請求有
   `"max_tokens": 8192`，暴走的那個沒有。
2. **context 依任務調整**，不要常駐 262144。這個工作負載的 prompt 是 6k 與 62k，32k–64k 就夠；
   256K 只是把「2 分鐘的錯誤」放大成「100 分鐘」。
3. **開 repetition / presence penalty**，`temperature` 不要太高。
4. **客戶端 watchdog**：串流只剩重複的 arguments、N 秒沒有文字或 finish 就 abort。
5. **重試前先取消**上一個請求；並且把「佇列深度」與「進度」分開看。
6. `reasoning_effort` 對這顆模型只支援 `'on'`（log 有 WARN），对齐设定，避免模型跑在非預期模式。
7. 需要時用 `~/.lmstudio/bin/lms ps` 看實際載入狀態；`Model unloaded by user or API request`
   是「有人/某個 API 卸載了它」，不是崩潰。

## 7. 可重複的判讀順序

1. 先找**引擎側**計數器：`n_gen`、`tg`、`n_decoded`、`stop processing`。
2. 再對照**顯示側**數字；兩者不一致時，先問「顯示在數什麼子集」。
3. 用 packet 組成做算術（本例：110 + 15 = 125），比任何猜測都快。
4. 確認有沒有 `finish_reason`；沒有就是「還在跑」，不是「跑完了」。
5. 才去排除資源、驅動、speculative decoding。

工具：`tools/linux/probe-sse-delta-mix.py`，直接吃 server log，輸出 delta 組成、每個
tool_call 的長度與重複週期。

```bash
python3 tools/linux/probe-sse-delta-mix.py \
  --log ~/.lmstudio/server-logs/2026-11/2026-11-18.28.log \
  --log ~/.lmstudio/server-logs/2026-11/2026-11-18.29.log \
  --log ~/.lmstudio/server-logs/2026-11/2026-11-18.30.log \
  --id chatcmpl-<id>
```
