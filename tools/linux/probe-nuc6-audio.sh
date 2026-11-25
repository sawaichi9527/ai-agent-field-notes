#!/usr/bin/env bash
# probe-nuc6-audio.sh — read-only health check for Intel NUC6 (Sunrise Point-LP HD Audio +
# Realtek ALC283) analog output on Ubuntu with PipeWire.
#
# Answers one question: is the silence a *config-layer* problem (driver grabbed by SOF/AVS,
# unknown model= string, runtime power save, card missing) or is the config layer fully open
# — in which case the remaining suspects are the codec's analog stage, the jack, or the speaker?
#
# Read-only: sysfs, /proc, amixer, pactl. No writes, no sudo.
# Exit 0 when the config layer is sane; 1 when something config-side must be fixed first.
#
# Used by ../cases/2026-11-25-nuc6-alc283-cold-boot-not-reboot/ and
# ../playbooks/0025-power-cycle-resets-what-reboot-cannot.md
export LANG=C LC_ALL=C

fail=0; warn=0
ok()  { printf '  [ OK ] %s\n' "$*"; }
ng()  { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
wk()  { printf '  [WARN] %s\n' "$*"; warn=$((warn+1)); }

# model names that actually exist in sound/pci/hda/patch_realtek.c for ALC283
KNOWN_ALC283_MODELS=" alc283-dac-wcaps alc283-sense-combo alc283-int-mic alc283-headset "

echo "== 1. driver knobs =="
dsp=$(cat /sys/module/snd_intel_dspcfg/parameters/dsp_driver 2>/dev/null || echo missing)
ps=$(cat  /sys/module/snd_hda_intel/parameters/power_save 2>/dev/null || echo missing)
mo=$(cut -d, -f1 /sys/module/snd_hda_intel/parameters/model 2>/dev/null)
[ "$dsp" = "1" ] && ok "snd_intel_dspcfg.dsp_driver=1 (legacy HDA)" || ng "dsp_driver=$dsp, expected 1"
[ "$ps" = "0" ]  && ok "snd_hda_intel.power_save=0"                 || ng "power_save=$ps, expected 0"
case "$mo" in
  ""|"(null)") ok "model unset (generic auto)" ;;
  *) case "$KNOWN_ALC283_MODELS" in
       *" $mo "*) ok "model=$mo is a known ALC283 fixup" ;;
       *) ng "model=$mo is NOT a fixup name; the driver ignores it silently. Known: $KNOWN_ALC283_MODELS" ;;
     esac ;;
esac
for m in snd_sof_pci_intel_skl snd_sof_intel_hda_common snd_soc_avs; do
  if awk -v m="$m" '$1==m{f=1} END{exit !f}' /proc/modules; then ng "$m is loaded (it can grab 00:1f.3)"; else ok "$m not loaded"; fi
done

echo "== 2. sound card =="
if grep -q '^ *0 \[PCH' /proc/asound/cards 2>/dev/null; then
  ok "card0: $(grep -m1 '^ *0 \[PCH' /proc/asound/cards | sed 's/^ *//')"
else
  ng "card0 absent (aplay -l would say 'no soundcards')"
fi

echo "== 3. combo jack =="
hj=$(amixer -c0 cget iface=CARD,name='Headphone Jack' 2>/dev/null | awk -F'values=' '/: values=/{print $2}')
mj=$(amixer -c0 cget iface=CARD,name='Mic Jack'       2>/dev/null | awk -F'values=' '/: values=/{print $2}')
if [ -n "$hj" ]; then
  echo "  Headphone Jack = $hj   Mic Jack = ${mj:-n/a}"
  [ "$hj" = "on" ] || wk "nothing detected in the headphone jack"
else
  wk "jack kcontrols unreadable (permissions?)"
fi

echo "== 4. sink =="
if command -v pactl >/dev/null 2>&1; then
  pactl list sinks 2>/dev/null | awk '
    /^\s+Name: /{name=$2} /^\s+State: /{st=$2} /^\s+Mute: /{mu=$2}
    /^\s+Volume: front-left:/{vol=$3" "$4" "$5} /^\s+Active Port: /{port=$3}
    END{printf "  sink=%s state=%s mute=%s vol=%s port=%s\n", name, st, mu, vol, port}'
else
  wk "pactl not available"
fi

echo "== 5. codec analog path =="
if [ -r /proc/asound/card0/codec#0 ]; then
  awk '
    /^Node 0x/{in2=($2=="0x02"); in21=($2=="0x21")}
    in2  && /Converter: stream=/{printf "  DAC 0x02: %s\n", $0}
    in21 && /EAPD 0x/{printf "  pin 0x21: %s\n", $0}
    in21 && /Pin-ctls:/{printf "  pin 0x21: %s\n", $0}
  ' /proc/asound/card0/codec#0
else
  wk "codec#0 unreadable (needs root or the audio ACL)"
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "VERDICT: config layer broken ($fail item(s)) — fix before blaming hardware."
  exit 1
fi
if [ "$warn" -gt 0 ]; then
  echo "VERDICT: config layer OK ($warn warning(s)). If still silent, the analog stage / jack /"
  echo "         speaker is the suspect — and remember: a power cycle resets what a reboot does not."
else
  echo "VERDICT: config layer fully open. If still silent, the problem is past the codec: analog"
  echo "         stage, jack, cable or speaker. Reboot will not reset it; remove AC power instead."
fi
exit 0
