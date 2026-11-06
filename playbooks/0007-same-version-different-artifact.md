# Playbook 0007 — A regression after an upgrade is a different artifact, not a worse version

**Applies to:** any host where a capability is delivered by an *optional* package, build variant,
or side-loaded artifact next to the mainline one — vendor "unattended"/"headless"/"pro" debs,
patched builds, feature-flagged binaries.
**Answers:** this worked yesterday, an update ran, and now it behaves like the old bug — did the
update regress, or did it replace the thing that was working?

## The trap

The version string is the only thing most people check, and it is the one thing that cannot tell
the two packages apart. A project can ship:

| package | version | conflicts | carries the fix |
|---|---|---|---|
| `app` (mainline) | 1.5.1 | — | no |
| `app-variant` (optional) | **1.5.1** | `Replaces: app` | yes |

Installing `app` **removes** `app-variant` as a side effect of `Conflicts/Replaces`, prints no
error, and `app --version` afterwards honestly reports `1.5.1`. Every check a user knows how to
run passes while the capability is gone.

That is why "the update brought the bug back" is the wrong hypothesis to start from. The update did
not make the software worse; it installed software that never had the fix.

## Ask three questions, in this order

1. **Which package is installed, and in what state?**
   Not "is it installed" — dpkg distinguishes `ii` (installed), `ic` (config files only, wanted
   installed), `rc` (removed, conffiles left), `un`. The letter pair is the answer, the version is
   not.

   ```bash
   dpkg -l app app-variant | tail -2
   ```

2. **Does the artifact that carries the capability exist, and who owns it?**

   ```bash
   dpkg -S /path/to/the/lib/that/does/the/thing
   ```

   If the path is absent, the build cannot do the thing at all, regardless of what the version
   says. This is the single most informative check.

3. **Is the process that is running the new artifact?**
   Package managers restart services with `enable; start`, and `start` on a live unit is a no-op.
   A freshly installed binary that has never been exec'd looks exactly like a broken fix.

   ```bash
   systemctl show <unit> -p MainPID -p ExecMainStartTimestamp
   ```

   Prefer a log line that **only the fixed build can emit** over a version check — see below.

## Rules

1. **Version is not identity.** Two artifacts with the same version can differ by the one feature
   you care about. Record *which package* produced the running binary, not just its number.
2. **`Conflicts/Replaces` with an equal version turns a downgrade into a clean-looking upgrade.**
   Suspect this whenever the "update" is a different package name than the one that fixed it.
3. **Find a log line only the fixed build can emit, and grep for it.** A green version check is
   worth nothing; `drm: consumer cache warmed` is worth a lot, because the portal build cannot
   print it.
4. **Restart before you diagnose.** Install → restart → verify, in that order, and keep the restart
   in its own command.
5. **Beware the service manager's own kill pattern.** A unit with `ExecStop=pkill -f "<app> --"`
   will match any shell command line containing that substring — including the verification
   command you just wrote next to the restart. Run them separately.
6. **When the sandbox blocks privilege escalation, change the escalation path, not the diagnosis.**
   With `no_new_privs` set, `sudo` fails no matter what; `pkexec --disable-internal-agent` lets the
   desktop's polkit agent ask the human who is already sitting there.
7. **State what you did not verify.** "Backend switched" and "capture works" are different claims;
   the second needs a real session, and the usual failure is a black frame, not an error.

## Worked example

[cases/2026-11-04-rustdesk-wayland-unattended](../cases/2026-11-04-rustdesk-wayland-unattended/) —
`rustdesk` 1.5.1 and `rustdesk-unattended-wayland` 1.5.1 are the same version, mutually
conflicting, and only the second one bypasses the Wayland consent portal. Updating to the official
1.5.1 with the standard deb removed the variant; `--version` still said 1.5.1.

Probe: [`tools/linux/probe-package-variant.sh`](../tools/linux/probe-package-variant.sh) answers
questions 1 and 2 in one call, and exits non-zero when the capability is missing:

```bash
tools/linux/probe-package-variant.sh rustdesk rustdesk-unattended-wayland '/usr/lib/rustdesk/libdrmtap.so.0*'
```
