# Case: RustDesk asks for screen-capture consent again after "updating to 1.5.1"

**Tool:** RustDesk 1.5.1 — standard deb, replaced by `rustdesk-unattended-wayland` 1.5.1 · **OS:** Ubuntu 26.04.1 LTS, GNOME Shell 50.1, Wayland · **Date:** 2026-11-04
**Full write-up:** [`write-up.md`](write-up.md) (Chinese, with the exact commands)

## Symptom

Every incoming connection pops GNOME's "allow screen sharing" dialog on the host, even though
RustDesk's own password is set. The machine had already been fixed once — with an experimental
1.5.1 build — and the dialog came back right after "updating to the official 1.5.1".

## Root cause

Not a RustDesk setting, and not a regression in 1.5.1.

On Wayland the standard `rustdesk` package captures through **XDG Desktop Portal**, so
`xdg-desktop-portal-gnome` asks the local user for consent on every new session. The
unattended capability lives in a **different package**, `rustdesk-unattended-wayland`, which
captures via **DRM/KMS in-process** (`libdrmtap`) and never talks to the portal.

Updating with the standard deb removed that variant. The two packages declare
`Conflicts / Replaces / Provides: rustdesk` **and ship the same version number**, so:

- `rustdesk --version` still prints `1.5.1` — looks correct;
- `dpkg -l` shows a row for `rustdesk` — looks installed;
- the artifact that implements the fix is simply gone.

Evidence from before the fix:

```
$ dpkg -l rustdesk rustdesk-unattended-wayland | tail -2
ii  rustdesk                     1.5.1     ← standard package, portal path
rc  rustdesk-unattended-wayland  1.5.1     ← the fixed variant, already replaced

$ ls /usr/lib/rustdesk/libdrmtap* ; echo $?
ls: cannot access '/usr/lib/rustdesk/libdrmtap*': No such file or directory
2
```

The server log confirms the portal path was live — a session is created and a `restore_token`
comes back, which is the handshake that ends in the consent dialog:

```
DEBUG [libs/scrap/src/wayland/pipewire.rs:623] Response from DBus: ... results: {"session_handle": ...}
DEBUG [libs/scrap/src/wayland/pipewire.rs:623] Response from DBus: ... "restore_token": ...
```

## Fix

Install the variant built for the **same** release, from the release page that also carries the
standard deb (`rustdesk-unattended-wayland-1.5.1-x86_64.deb`, published 2026-11-01, ships
`libdrmtap.so.0.5.12`):

```bash
pkexec --disable-internal-agent /usr/bin/dpkg -i "$PWD/rustdesk-unattended-wayland-1.5.1-x86_64.deb"
```

dpkg reports `為了 rustdesk-unattended-wayland，正打算移除 rustdesk` — that removal is the
expected consequence of `Conflicts/Replaces`, and `~/.config/rustdesk/` (and therefore the
RustDesk ID) survives.

**Then check that the running process is the new build.** The postinst only does
`systemctl enable; systemctl start`; when the unit is already running, `start` is a no-op and the
old binary keeps serving. Here the unit happened to be unloaded during the swap, so it came up
fresh — but do not rely on that.

## Verification

```bash
tools/linux/probe-package-variant.sh rustdesk rustdesk-unattended-wayland '/usr/lib/rustdesk/libdrmtap.so.0*'
```

| Check | Result |
|---|---|
| variant package state | `installed`; base is `config-files only` |
| capability artifact | `libdrmtap.so.0.5.12` present, owned by the variant |
| backend actually taken over | `drm: consumer cache warmed (1 displays) at startup` (`src/server/drm_capturer.rs:2029`) |
| portal requests after the switch | none in any log written after the restart |
| RustDesk ID | unchanged (`enc_id` identical before and after) |
| display present for DRM to scan out | `card1-HDMI-A-1 connected`, matching `1 displays` |
| desktop kept awake (DRM needs a live CRTC) | `idle-delay=0`, `sleep-inactive-ac-type=nothing` |

**Not verified: a live connection from another machine.** No connection was attempted between the
switch and this write-up — the hourly server logs contain startup lines only. The evidence above
shows the DRM backend took over and the portal path is no longer exercised at startup; it does not
prove that a real session captures correctly (the known failure mode is a black frame, not a
dialog). Test it before calling it done.

## Transferable lessons

| Lesson | Why it generalises |
|---|---|
| **A version number is not an identity** | two packages can both be `1.5.1` and one of them cannot do the thing; check the artifact that carries the capability, not the version string |
| **Conflicting variants make a downgrade look like an upgrade** | `Conflicts/Replaces` + identical version = the wrong one installs cleanly and reports the right number |
| **"It came back after updating" usually means the fix was in a different artifact** | the update did not regress; it replaced what was working |
| **Verify the running process, not the installed package** | postinst `start` is a no-op on a live unit; compare the log line emitted by the new build, or the process start time |
| **Choose a verification that can fail in a distinctive way** | `drm: consumer cache warmed` only exists in the DRM build — its absence/black-frame would be the tell |

## Open

- The end-to-end connection test (consent gone, picture correct, repeat connection) — see above.
- The standard package remains in `config-files only` state; `dpkg --purge rustdesk` would tidy it,
  but it is also a live reminder of which package is authoritative.
- Pin the upgrade path: every future release must be taken from the
  `rustdesk-unattended-wayland-<version>-x86_64.deb` asset, never the standard deb. Consider a
  wrapper script that refuses to install a standard `rustdesk` deb on this host.
- The capability is x86_64-only as of 1.5.1; on aarch64 the fallback is GNOME's built-in RDP
  (`grdctl rdp enable`), which is a different client.
