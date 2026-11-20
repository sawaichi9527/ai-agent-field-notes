# ROCm 10.1 → 10.2：不是升級，是並存（而且回滾只要一行）

> 2026-11-20 · ROCm Core SDK 10.1.0-3 → 10.2.0-2（TheRock `amdrocm*`）
> · Ryzen AI Max+ PRO 495 / Radeon 8065S（`gfx1151`）、160 GiB GTT、182 GiB 統一記憶體
> · Ubuntu 26.04.1、kernel `7.0.0-44-generic`、inbox `amdgpu`

## 1. 需求不是「升到 10.2」，而是「升上去而且回得來」

ROCm 10.2.0 在 2026-11-18 發布，這台機器當時跑 10.1.0（2026-10-12 裝的）。真正的要求是
**同時保有兩個版本**，因為 AI 堆疊（PyTorch / vLLM / 自編譯程式）對版本很敏感，出問題要能
在幾秒內切回上一個版本，而不是重裝。

結果：10.2 與 10.1 是**兩組獨立的套件**（各 55 個），安裝後 10.1 原封不動，切換由
`update-alternatives` 決定。**回滾 = 改 26 個 alternatives 的指向**，代價 0 下載、0 重裝。

## 2. 先確認封裝模型，兩個常見指令都是錯的

| 指令 | 實際結果 |
|---|---|
| `sudo apt update && sudo apt full-upgrade` | **不會**升到 10.2。`apt list --upgradable` 裡沒有任何 `amdrocm*`（10.1 的 meta 不依賴 10.2） |
| `sudo apt install amdrocm`（無版本、無 gfx） | 會拉**全部** gfx 架構，6 GB+。APU 只要 `-gfx1151` 變體 |
| `sudo apt install amdrocm-core-sdk10.2-gfx1151` | 正確：並存安裝，且不會移除 10.1 |

套件名與安裝目錄都帶 `major.minor`（`amdrocm-*10.1` → `/opt/rocm/core-10.1`），所以兩個版本
本來就可以共存；「現在是哪一版」純粹是 alternatives 的問題。

事前用 `apt-get -s`（唯讀模擬）確認：

```
0 upgraded, 55 newly installed, 0 to remove and 1 not upgraded
```

**「0 to remove」是這種升級的安全門檻**——只要模擬結果出現 `Remv`，就代表會動到既有版本，
應該停下來看清楚。這次唯一的「1 not upgraded」是 `python3-jwt`，與 ROCm 無關。

## 3. 安裝與切換

安裝 1,058 MB / 約 2 分鐘，磁碟增加 9,742 MB（實測 `du` 9.2 GB）。10.2 的 `postinst` 自己把
26 個 alternatives 群組切到 `core-10.2`，包含 `core`、`core-10`、`hipcc`、`rocminfo`、
`amd-smi`、`rocm-bin`、`rocm-lib`、`amdclang*` 等，所以**不需要手動切**。

驗證（一般使用者，非 root）：

```
AMD SMI 27.2.0 · ROCm version 10.2.0
HIP 7.17.26434 · clang 24.0.0git
rocminfo: Runtime 1.21, Marketing Name AMD Ryzen AI Max+ PRO 495, gfx1151
HIP 向量加 419 萬元素：RESULT: PASS，0 mismatches
```

回滾（10.1 從未被動到）：

```
sudo update-alternatives --set core /opt/rocm/core-10.1
# 其餘群組用工具一次處理：
sudo bash tools/linux/rocm/rocm-version-switch.sh --use 10.1
```

## 4. 效能：兩次「看起來像迴歸」的假象

### 假象一：62.8 GB/s

`--verify` 的煙測程式只發射 **1 次** kernel、沒有 warmup。10.1 量到 0.532 ms / 94.6 GB/s、
10.2 量到 0.801 ms / 62.8 GB/s，看起來像 34% 退化。實際上第一次啟動包含 module load 與時脈
拉升；換成 warmup 10 次 + 30 次取樣後，兩版都在 **237–242 GB/s**（256-bit LPDDR5X 理論值
256 GB/s 的 93–95%）。

### 假象二：+2.2%

用 16M floats（每輪 192 MiB 流量）做 A/B：

| 輪次 | 順序 | 結果 |
|---|---|---|
| A | 10.1 → 10.2 | 10.2 慢 2.2% |
| B | **10.2 → 10.1** | 10.2 **快** 1.4% |
| C | 同一個 binary 只換 runtime | 10.2 慢 1.0% |
| D | A/B/B/A、每次量測前冷卻 20 s、各 50 次取樣 | 10.1 平均 0.8414 ms、10.2 平均 0.8418 ms → **+0.05%** |

反轉順序後慢的那一方就換人，代表差異來自**順序**（第二個量測永遠慢 1–2%），不是版本。
加入冷卻後，四個量測值全距只有 0.9%。

**結論：10.2 與 10.1 效能等價**（差異 < 量測解析度 ±0.5%）。

## 5. PyTorch：10.2 起 wheel 自帶一份 ROCm

`torch==2.15.0+rocm10.2.0` 安裝時會一併拉進 `rocm-sdk-core`、`rocm-sdk-libraries`、
`amd-torch-device-gfx1151`、`triton` 等，venv 共 **6.8 GB**，而且：

```
$VENV/lib/python3.14/site-packages/_rocm_sdk_core/lib/libamdhip64.so.7
libtorch_hip.so 的 RUNPATH = $ORIGIN/../../_rocm_sdk_core/lib/…
```

**torch 用的是 venv 內自帶的 ROCm，不是 `/opt/rocm`。** 兩個推論：

- 系統切回 10.1 **不會**影響已建好的 venv；要「torch 跑 10.1」得另建 venv 並 pin `+rocm10.1.0`。
- 系統 `/opt/rocm` 只影響 `hipcc` 編譯的 C++ 與 CLI 工具。

實測：`torch 2.15.0+rocm10.2.0`、`HIP 7.17.26434`、1024² matmul 與 CPU 的 `max abs err
2.289e-04`（相對 ~7e-6）、`torchvision 0.29.2` 的 `ops.nms` 正常。

### `torch.compile` 需要 `python3.14-dev`

第一次跑 `torch.compile` 失敗在：

```
fatal error: Python.h: 沒有此一檔案或目錄
-I/usr/include/python3.14
```

不是 ROCm 的問題：Inductor 會用 gcc 編譯 `hip_utils.c`，需要 Python 標頭檔。裝
`python3.14-dev` 後首次編譯 **2.0 秒**，編譯後 **1.09 ms/step**（eager 12.87 ms/step，
**快 11.8 倍**）。腳本已自動 `DISABLE_ADDMM_HIP_LT=1`（把 GEMM 導向 rocBLAS，避開 gfx1151
的 hipBLASLt 缺 fallback kernel），這也是編譯只花 2 秒而不是數分鐘的原因。

## 6. 同一個經驗能不能搬到 395？

可以，而且不需要改任何腳本：

| | Ryzen AI Max+ 395（Strix Halo） | PRO 495（Gorgon Halo） |
|---|---|---|
| gfx target | `gfx1151` | `gfx1151` |
| ROCm 套件 | 同一個 `amdrocm-core-sdk10.2-gfx1151` | 同一個 |
| 核心需求 | 同一組 KFD 修正（Ubuntu 26.04 GA 已含） | 同上 |
| 差異 | 核心數、記憶體容量、絕對頻寬 | 同上，數值不同 |

腳本用 `dpkg` 的套件後綴自動辨識 gfx，不寫死型號；`--gfx` 可覆蓋。真正要重跑的是
「驗證」與「效能基線」，因為這兩項跟散熱與記憶體配置有關。

## 7. 給下一個人的三條規則

1. **先看封裝模型，再談升級**：套件名/目錄帶 `major.minor` 就代表可並存，回滾成本幾乎為零。
2. **用 `apt-get -s` 把「0 to remove」變成安裝前的門檻**，而不是安裝後才後悔。
3. **版本比較一定要配對量測**：warmup、冷卻、A/B/B/A、比同位置；單次量測的差異 90% 是雜訊。
