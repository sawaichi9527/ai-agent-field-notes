# Case: `apt update` prints three `Notice:` lines — two arch skips and one empty `Signed-By`

**Tool:** apt 3.2.1, Ubuntu 26.04.1 LTS (`resolute`), `i386` enabled as a foreign architecture ·
**Date:** 2026-11-13
**Full write-up:** [`write-up.md`](write-up.md) (Chinese, with the exact commands and verification log)
**Reusable recipe:** [`fix-apt-notices.sh`](fix-apt-notices.sh)

## Symptom

Every `apt update` ends with three lines that look like failures but are not:

```
Notice: Skipping acquire of configured file 'main/binary-i386/Packages' as repository
        'https://deb.nodesource.com/node_24.x nodistro InRelease' doesn't support architecture 'i386'
Notice: Skipping acquire of configured file 'proprietary/binary-i386/Packages' as repository
        'https://workbench.download.nvidia.com/stable/linux/debian default InRelease' doesn't support architecture 'i386'
Notice: Missing Signed-By in the sources.list(5) entry for
        'https://workbench.download.nvidia.com/stable/linux/debian'
```

Updates and installs still work, signatures still verify, nothing is broken. That is exactly why
these survive for years: they are deprecation nudges and skipped-index messages, not errors.

## Root cause — three notices, two mechanisms

| # | Notice | Mechanism |
|---|---|---|
| 1, 2 | `doesn't support architecture 'i386'` | `i386` is a foreign architecture (`dpkg --add-architecture i386`, kept for Steam/Wine), but both third-party repos publish **amd64 only**. apt expands one index target per configured architecture and skips the ones the repo's `Release` does not list. |
| 3 | `Missing Signed-By` | the entry was rewritten by `apt modernize-sources` from a legacy `.list`. The converter emitted `Signed-By:` with an **empty value** while the key stayed in `/etc/apt/trusted.gpg.d/`. apt ≥ 2.9.24 deprecates both empty `Signed-By` and the global `trusted.gpg.d` directory, so it notices — while still verifying through the legacy keyring. |

Two plausible "fixes" are both wrong here:

- **removing `i386`** would silence #1/#2 but also the future `steam-installer` / Wine 32-bit
  dependencies — the architecture is wanted, just not on repos that do not carry it;
- **deleting the NVIDIA repo** would silence #2/#3 but cut `nvidia-sync`'s update channel; that
  package is the SSH-tunnel client used to reach a DGX Spark, and the repo's only other packages
  (`nvidia-ai-workbench`, `nvidia-workbench`) are not installed.

Scope the change to the entry, per repository.

## Fix

```bash
sudo install -m 0644 /etc/apt/trusted.gpg.d/ai-workbench-desktop-key.asc \
                   /usr/share/keyrings/ai-workbench-desktop-key.asc

sudo sed -i '/^Components:/a Architectures: amd64' \
  /etc/apt/sources.list.d/nodesource.sources

sudo sed -i -e '/^Components:/a Architectures: amd64' \
  -e 's|^Signed-By:.*|Signed-By: /usr/share/keyrings/ai-workbench-desktop-key.asc|' \
  /etc/apt/sources.list.d/stable-linux-debian-default.sources
```

Resulting diff (backup kept at `/etc/apt/sources.list.d.bak.<timestamp>`):

```diff
 Components: main
+Architectures: amd64
 Signed-By: /etc/apt/keyrings/nodesource.gpg

 Components: proprietary
-Signed-By:
+Architectures: amd64
+Signed-By: /usr/share/keyrings/ai-workbench-desktop-key.asc
```

**Keep the `.asc` extension.** An ASCII-armored key renamed to `.gpg` is rejected with
`the file has an unsupported filetype` — apt picks the key format by extension, not by sniffing the
content. If the official `.gpg` name matters, dearmor first:
`sudo gpg --dearmor -o /usr/share/keyrings/ai-workbench-desktop-key.gpg <keyfile>`.

## Verification

Two checks are needed; either one alone can pass while the problem remains.

| Check | What it proves | Observed |
|---|---|---|
| `apt-get update` **on a tty** | the notices are actually gone, not filtered | 12/12 sources `Hit`, `Notice:`/`W:`/`E:` = 0, exit 0 |
| fresh `Dir::State::Lists`, both repos re-downloaded | the new `Signed-By` path really verifies, and only `amd64` is fetched | `Get:` ×4 (2 × `InRelease`, 2 × `amd64 Packages`), 0 warnings |
| `dpkg --print-foreign-architectures`; `apt-cache policy libc6:i386` | `i386` capability survived | `i386`; candidate `2.43-2ubuntu2.7` from `…/resolute-updates/main i386 Packages` |
| `apt-cache policy nvidia-sync` | repo still serves the installed package | candidate unchanged (`0.148.0~153-5805`) |

The first check matters because apt prints `Notice:` only when stdout is a tty. In a pipe the lines
vanish entirely — a captured run reports zero notices for a machine that shows three. See
[playbook 0011](../../playbooks/0011-terminal-only-output-is-not-the-output.md).

## Transferable lessons

| Lesson | Why it generalises |
|---|---|
| **A `Notice:` is a deprecation nudge, not a failure** | the command's exit code and the repo's usability are unaffected; treat notices as a "will break one day" queue, not as breakage |
| **The notice names the mechanism, not the fix** | `Missing Signed-By` means "state who signs this", which can be satisfied by a key file path or by removing the need for the entry — decide which |
| **Never drop a multi-arch architecture to silence a per-repo skip** | `i386` serves Steam/Wine from the distro archive; scope `Architectures:` to the repo that lacks the index |
| **Check who consumes a repo before deleting it** | the NVIDIA repo's only installed package was `nvidia-sync`, not the app in its name; `apt-cache policy` shows which package actually comes from there |
| **`Hit` hides signature changes** | a cached `InRelease` is not re-verified; re-download with a fresh lists dir to prove a `Signed-By` change |
| **Pipes delete `Notice:` lines** | measure the terminal, not the pipeline (playbook 0011) |

## Open

- Debian bug [#1107140](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1107140) — the
  `modernize-sources` empty-`Signed-By` writer is still open; the notice will come back on the next
  migration of a legacy entry.
- If the NVIDIA installer (or another `apt modernize-sources` run) rewrites
  `stable-linux-debian-default.sources`, re-run `fix-apt-notices.sh`; it is idempotent.
