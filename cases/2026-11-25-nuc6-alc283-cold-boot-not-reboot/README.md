# Case: the codec was fully open and still silent — a power cycle resets what a reboot does not

**Tool:** ALSA 1.2.15.3 + PipeWire 1.6.2 · **Hardware:** Intel NUC6i5SYH (i5-6260U,
Sunrise Point-LP `8086:9d70` + Realtek ALC283 `8086:2063`) · **OS:** Ubuntu 26.04.1 LTS
(GNOME 50, kernel `7.0.0-44-generic`) · **Date:** 2026-11-25
**Full write-up:** [`write-up.md`](write-up.md) (Chinese, with the numbers and the false starts)
**Probe:** [`tools/linux/probe-nuc6-audio.sh`](../../tools/linux/probe-nuc6-audio.sh)

## Symptom

The speakers are silent after a boot, while GNOME Sound shows **"Headphones · Internal
Audio" at 100 %**, the card present, and no input device. Rebooting again changes nothing.
Plugging/unplugging the speaker produces an audible click, so the speaker and the cable are
alive. The machine is a single-OS Ubuntu box (no Windows on it).

Every layer that people normally check reports healthy: card registered, sink unmuted at
0 dB, jack "plugged", PCM clocking at 48 kHz, stream bound to the DAC, every amp in the
playback path unmuted, EAPD on.

## What was measured

| Question | Answer (during the silent warm boot) |
|---|---|
| Is the card there? | yes — `card0 [PCH] HDA-Intel - HDA Intel PCH`, ALC283 + Skylake HDMI |
| Does the codec see the plug? | yes — `Headphone Jack` = `on`, `Mic Jack` = `off` (3-pole plug on the combo jack) |
| Is the sink muted / turned down? | no — `Mute: no`, 100 % / 0.00 dB, port `analog-output-headphones` |
| Is the PCM actually moving? | yes — `hw_ptr` +48,576 frames in 1.01 s ≈ 48.0 kHz; a 2.000 s file took **2.087 s** to play |
| Is the stream on the right converter? | yes — `Node 0x02 Converter: stream=1` while playing |
| Are the analog stages open? | yes — DAC `0x57` (0 dB), mixer `0x0c` input 0 (`0x02`) unmuted, pin `0x21` amp `0x00`, `Pin-ctls 0xc0: OUT HP`, `EAPD 0x2` |
| Does the configured `model=` explain it? | **no** — `alc283-dac` is not a fixup name; the codec stayed on the generic auto-parser |
| What differed between silent and audible? | only the **power cycle**: identical autoconfig, `model` gone from `alc283-dac` to `(null)` |

Evidence: [`evidence/before-warm-boot.txt`](evidence/before-warm-boot.txt),
[`evidence/after-cold-boot.txt`](evidence/after-cold-boot.txt).

## The two traps this case exists to show

**1. An unknown `model=` string is accepted silently and manufactures a cause.** The
driver records the parameter (it shows up in
`/sys/module/snd_hda_intel/parameters/model`), fails to match it against the fixup table,
and falls back to auto without printing an error. Two such strings were in play here across
the machine's history — `alc283-dac` and `intel-nuc-headset-jack` — and **neither exists**;
ALC283 has exactly four names (`alc283-dac-wcaps`, `alc283-sense-combo`, `alc283-int-mic`,
`alc283-headset`). Because the autoconfig line is the same either way, the fix "looked
applied" for months and was credited for a recovery it never caused.

**2. "Registers open + jack detected + PCM clocking" is not "audible".** The codec's analog
stage can latch in a state that reads perfectly healthy. The reset boundary for that state
is the **AC rail**, not a reboot: the silence survived warm reboots (the 19:40 boot was itself a
reboot and stayed silent), and a shutdown + 10 s unplug restored sound with *the same* register
dump.

## Reproduce

```bash
tools/linux/probe-nuc6-audio.sh        # read-only: knobs, card, jack, sink, codec path
# the only experiment that discriminates:
#   shutdown, unplug AC for 10 s, boot, then run the same probe again
```

## Applies to

Skylake NUCs with the ALC283 combo jack (NUC6i5SYH / NUC6i5SYB) are the concrete instance.
The two rules generalise to any HDA codec: an analog stage can latch until the rail drops,
and a `model=` value that the kernel does not know is indistinguishable from success unless
you read the autoconfig line and the fixup table.
