# 0025 — A codec's analog state is reset by the power rail, not by a reboot

**Claim.** On an HDA codec, "the PCM is running, the sink is unmuted, the jack is detected and
every amp in the path is open" does **not** mean "audible". The digital path can be measurably
perfect while the analog stage sits latched in a state that no register in the path reflects.
`reboot` re-runs the driver's init verbs but keeps standby power on, so it cannot clear that
state; removing AC power can. And when a machine carries a `model=` in
`/etc/modprobe.d/`, test the **autoconfig line**, not sysfs: the driver records an unknown fixup
name without complaint and silently stays on the generic parser.

## The questions, in order

1. **Is the digital path actually running, and is it on the right converter?**

   ```sh
   cat /proc/asound/card0/pcm0p/sub0/status   # twice, ~1 s apart, while playing a known-length file
   grep -A2 'Converter: stream=' /proc/asound/card0/codec#0
   ```

   `hw_ptr` must advance at the sample rate (48,576 frames per 1.01 s at 48 kHz) and the
   playback file must take its real duration — a null sink also "plays", so wall time alone is
   not enough. Then confirm the stream landed on the DAC that feeds the pin (`Node 0x02
   Converter: stream=1`), not on a sibling converter.

2. **Is the analog path open?**

   ```sh
   awk '/^Node 0x/{n=$2} /Amp-Out vals|Pin-ctls|EAPD 0x/{print n, $0}' /proc/asound/card0/codec#0
   amixer -c0 cget iface=CARD,name='Headphone Jack'
   ```

   Check every stage, not just the sink: DAC gain (`0x57` = 0 dB), the mixer input that selects
   the DAC (its `Amp-In` must not carry `0x80`), the pin's `Amp-Out` (`0x00` = unmuted),
   `Pin-ctls` (`0xc0` = OUT + HP), `EAPD 0x2`, and that the jack kcontrol says `on`.

3. **Does the configured `model=` even exist?**

   ```sh
   cut -d, -f1 /sys/module/snd_hda_intel/parameters/model   # proves it was recorded, nothing else
   journalctl -k -b 0 | grep 'autoconfig for'
   ```

   The oracle is the autoconfig line. If it reads the generic shape (`line_outs=1 (0x21) … type:hp`,
   `hp_outs=0`) both with and without the string, the string matched nothing. Confirm against
   `sound/pci/hda/patch_realtek.c`'s fixup-name table rather than against a forum post.

4. **What resets the state you cannot see?**

   Repeat the measurement after a **shutdown + AC removal (10 s) + boot**, not after a reboot.
   If the register dump and the autoconfig are identical but the sound is back, the only variable
   was the power rail — stop looking for a software cause.

## The rules that survive this case

- **"All registers open" is a claim about the digital path.** The analog stage is a separate
  domain; no amount of `amixer` unmuting proves it is driving a load. When everything measures
  open and nothing is audible, suspect the stage, the jack, or the speaker — in that order.
- **`model=` is accepted silently, so it manufactures false causality.** A value that looks
  applied for months may never have matched. Record the autoconfig line in the case file, or the
  next person will credit the string for a recovery it did not cause.
- **Choose the reset unit deliberately.** "Reboot" resets software; it does not drop the rail.
  Before declaring a fault fixed or permanent, ask what the state is held by — and test that
  exact boundary once.
- **Retire a probe that cannot see the effect.** A loopback that captures a mixer the DAC never
  enters will report silence on a working machine. A negative result from an incapable probe is
  not evidence (methodology §2) — write down why it was retired.
- **Keep the pair.** The before/after evidence is the proof: same codec dump, same autoconfig,
  different power history, different outcome.

## Evidence

- [`cases/2026-11-25-nuc6-alc283-cold-boot-not-reboot/`](../cases/2026-11-25-nuc6-alc283-cold-boot-not-reboot/) —
  the full before/after transcripts, the codec path dump, and the retired loopback probe
- [`tools/linux/probe-nuc6-audio.sh`](../tools/linux/probe-nuc6-audio.sh) — read-only: driver
  knobs (including the unknown-`model=` check), card, jack, sink, codec analog path; exit 1 when
  the config layer is broken

## Limits

- The concrete instance is an ALC283 on a Skylake NUC6, where the latching survived warm reboots
  and cleared only on AC removal. Whether a given codec latches is a per-part fact — the method (separate the
  digital measurement from the reset boundary) is the portable part.
- "Cold boot" means the standby rail actually drops. A laptop with the battery still installed,
  or a desktop on a powered USB hub, may keep 5 V standby through a "shutdown"; remove the
  battery/AC, not just press the power button.
- This playbook does not cover the case where the card never appears (driver grabbed the device
  or codec probe failed) — check `dsp_driver`, SOF/AVS and the `autoconfig` line for that.
