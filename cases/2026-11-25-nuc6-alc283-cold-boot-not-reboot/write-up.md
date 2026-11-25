# NUC6i5SYH 無聲：codec 全開卻不響，因為重置的單位是「電源」不是「重開機」

> 2026-11-25 · Intel NUC6i5SYH（i5-6260U，Sunrise Point-LP `8086:9d70` + Realtek ALC283 `8086:2063`）
> · Ubuntu 26.04.1 LTS（GNOME 50，kernel `7.0.0-44-generic`）· 單一 OS，機器上沒有 Windows
> · 需求：找出「喇叭沒聲音」的原因，不要再用猜的換參數

## 1. 症狀：所有該檢查的都說正常

開機後喇叭沒聲音。GNOME 聲音設定顯示輸出裝置是「頭戴式耳機 - 內部音效」、音量 100%、
輸入裝置「沒有輸入裝置」。重開機幾次都一樣。

日常會做的檢查全部正常：

- 音效卡存在（`card0 [PCH] HDA-Intel`）
- sink 沒靜音、音量 100% / 0.00 dB
- 插孔偵測說有插頭（`Headphone Jack = on`）
- 播放時的 PCM 時鐘真的在跑

唯一「不正常」的線索反而是好事：插拔喇叭線時喇叭會「波」一聲，代表喇叭、線、插孔都有通。

## 2. 先把「PipeWire → codec」整條鏈量完

| 問題 | 量到什麼 |
|---|---|
| 音效卡在不在 | `card0 [PCH] HDA-Intel - HDA Intel PCH`，ALC283 + Skylake HDMI |
| codec 有沒有看到插頭 | `Headphone Jack = on`、`Mic Jack = off`（三極插頭插在 combo jack 上） |
| sink 有沒有被靜音/轉小 | `Mute: no`、100%、port `analog-output-headphones` |
| PCM 有沒有真的在跑 | `hw_ptr` 1.01 秒前進 **48,576 frames ≈ 48.0 kHz**；2.000 秒的音檔實際播了 **2.087 秒** |
| 串流有沒有綁在正確的 DAC | 播放時 `Node 0x02 Converter: stream=1` |
| 類比段有沒有關 | DAC `0x57`（0 dB）、mixer `0x0c` 輸入 0（`0x02`）未靜音、pin `0x21` amp `0x00`、`Pin-ctls 0xc0: OUT HP`、`EAPD 0x2` |

也就是說：**訊號已經被送到 codec 的類比輸出級，而且該開的都開了。** 這條鏈上沒有任何
一處能解釋「沒聲音」。

證據：[`before-warm-boot.txt`](evidence/before-warm-boot.txt)、
[`after-cold-boot.txt`](evidence/after-cold-boot.txt)。

## 3. 假線索一：`model=` 是空包彈

這台機器歷史上被寫過兩個 `model=`：

```
options snd-hda-intel model=alc283-dac          # 現行檔案
options snd-hda-intel model=intel-nuc-headset-jack   # 舊筆記
```

**兩個都不存在。** 查 `sound/pci/hda/patch_realtek.c` 的 fixup 名稱表，ALC283 只有：

```
{.id = ALC283_FIXUP_CHROME_BOOK,        .name = "alc283-dac-wcaps"},
{.id = ALC283_FIXUP_SENSE_COMBO_JACK,   .name = "alc283-sense-combo"},
{.id = ALC283_FIXUP_INT_MIC,            .name = "alc283-int-mic"},
{.id = ALC283_FIXUP_HEADSET_MIC,        .name = "alc283-headset"},
```

而且整張表**沒有任何名稱含 nuc 的項目**——NUC 的 quirk 是用 `SND_PCI_QUIRK` 認 subsystem ID
（NUC 8 `0x2074/0x2080`、NUC 10 `0x2081`、NUC 13 `0x3038`），不是靠 model 字串；NUC6 的
`0x2063` 根本不在表裡。

driver 對不認識的 model 是**靜默退回 auto、不報錯**，所以 `sysfs` 看得到值：

```
$ cut -d, -f1 /sys/module/snd_hda_intel/parameters/model
alc283-dac
```

但 codec 的 autoconfig 仍是純 generic（`line_outs=1 (0x21) type:hp`、`hp_outs=0`），
跟沒有設 model 時一字不差。這正是最惡劣的一種假因果：**參數看起來「有套用」，於是它被
記成「修好過」，實際上它從頭到尾沒作用。**

順帶把舊筆記的另一個說法也證偽：它說 `intel-nuc-headset-jack` 會「指派 0x21（耳機）與
0x14（喇叭）」。但 0x14 在這台是 `0x411111f0 [N/A]`（停用），而且 NUC6i5SYB 沒有內建
喇叭，0x14 沒有接任何東西。

## 4. 假線索二：loopback 錄不到音，不代表沒訊號

ALC283 有 `Loopback Mixing` 開關，我試著「不靠耳朵」驗證 DAC：餵 440 Hz、同時從
`hw:0,0` 錄回來，找頻譜。結果錄到 `peak 0.00391`、440 Hz 只有 **-98.7 dBFS** ——看起來像
「DAC 沒輸出」。

**這個結果不能算證據。** 這顆 codec 的 ADC 抓的是 `0x0b`，而 `0x0b` 是麥克風/beep
mixer：

```
Node 0x0b [Audio Mixer]
  Connection: 5
     0x18 0x19 0x1a 0x1b 0x1d      # mic pins + beep，沒有 DAC
```

DAC `0x02` 是經 `0x0c` 到 pin `0x21`，**永遠不會經過 `0x0b`**，所以 loopback 根本承載不了
播放訊號。探針看不到它要測的效應，就不該被解讀（methodology §2）。
完整記錄：[`loopback-probe.txt`](evidence/loopback-probe.txt)。

## 5. 決定性對照：冷啟動前後，autoconfig 一字不差

最後一步是「關機 → 拔電源線 10 秒 → 插回開機」。結果：

| | 無聲（暖開機） | 有聲（冷啟動後） |
|---|---|---|
| boot | 19:40:01（reboot，未斷電） | 20:35:33（拔電源 10 秒） |
| `model` 參數 | `alc283-dac` | `(null)`（新設定，無 model） |
| autoconfig | `line_outs=1 (0x21) type:hp`, `hp_outs=0` | **完全相同** |
| codec 路徑 | 全開（見 §2） | 全開（同一份 dump） |
| 聲音 | 無 | **有** |

唯一的變數是「有沒有把電放掉」。這排除了所有設定層的解釋：如果 autoconfig 一樣、register
一樣、PCM 一樣，差別只能是 codec 的類比級在斷電後被重置了。

## 6. 為什麼 reboot 不夠

`reboot` 只重跑 driver 的 init verbs，**不會切斷待機電源**。ALC283 的類比輸出級（EAPD /
COEF 那一組暫存器）一旦被留在錯誤狀態，register 讀起來全部正常，但實際不出聲；只有讓
電源軌真正掉一次，那組類比狀態才會回到預設。

當晚的幾次 reboot（包含 19:40 那次）都沒有改變任何 register，10 秒的斷電卻一次就解決。

## 7. 三條規則

1. **「register 全開」不是「有聲音」。** 量到的是數位路徑（PCM 在跑、DAC 有綁、amp 未靜音），
   類比級可以在這一切之外卡住。要證明有聲，只能靠耳朵或一條實體 loopback 線。
2. **`model=` 要對照 autoconfig，不是對照 sysfs。** sysfs 只證明參數被記錄，不證明被匹配。
   驗證方式是看 dmesg 的 `autoconfig for ALC283:` 那行有沒有變，或直接查 fixup 名稱表。
3. **「重置」的單位要選對。** 對會 latch 的 codec/韌體狀態，`reboot` 與「斷電」是兩種不同的
   操作；先問「這個狀態是被什麼保存的」，再選復位方式。

## 工具

- [`tools/linux/probe-nuc6-audio.sh`](../../tools/linux/probe-nuc6-audio.sh) — 唯讀：
  driver 參數、card、jack、sink、codec 類比路徑；設定層有問題時 exit 1。
- 設定檔範本：[`nuc-audio-fix.conf`](nuc-audio-fix.conf)（只有 `dsp_driver=1`、
  `power_save=0/controller=0`、三條 blacklist；刻意不設 `model=`）。
