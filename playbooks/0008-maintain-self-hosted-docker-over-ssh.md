# Playbook 0008 — Maintain a self-hosted docker service over SSH: check → backup → apply → verify

**Applies to:** any self-hosted `docker-compose` service on a remote / LAN host that you reach only
over SSH with a password-bearing account (ForgeJo / Gitea / similar).
**Answers:** how to upgrade or repair such a service without ending up with no backup and a broken
deploy.

This is the method behind
[`cases/2026-11-08-forgejo-self-hosted-upgrade/`](../cases/2026-11-08-forgejo-self-hosted-upgrade/).
It is not about upgrading the agent itself — use `hermes-upgrade-verify` for that.

## The order (do not skip the backup verification)

1. **Inspect without changing state.** Find the compose file, the current image tag, the data layout,
   the DB type, and free space. Assume nothing about paths.
2. **Back up, then prove the backup exists** before touching anything. (The permission rules below
   are why this deserves its own section.)
3. **Apply with minimal downtime.** Pull first (old container still runs), then recreate.
4. **Verify** version endpoint, `docker ps`, logs, and the one feature you actually care about.

## Step 1 — Inspect (read-only)

```bash
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"          # current image + container
docker inspect <service>                                                # bind-mounts → host data dir
grep DB_TYPE <data>/gitea/conf/app.ini                                  # sqlite vs external postgres/redis
df -h <data-mount-point>                                                # headroom for the backup
```

Two things this decides: **where** the backup must go (who owns the data tree) and **what** must be in
it (a whole volume for SQLite; just the DB container + dump for external postgres).

## Step 2 — Back up, and prove it (the part that usually breaks)

The naive command fails in two independent ways on a real host:

- **You cannot write where you would like.** The data root is often owned by `root`; the SSH user can
  list it but not create the archive there. Write to a path the SSH user actually owns (`~/`, or a
  subdir of the data tree that is theirs).
- **Something inside is not readable.** A `700` subtree (SSH host keys, session dir) owned by `root`
  makes `tar` exit non-zero. That *looks* like "no backup," but it may only be one unreadable branch.

```bash
# write to a writable path; skip the subtree you cannot read
tar --exclude='data/ssh' -czf ~/backup-<service>-$(date +%Y%m%d-%H%M%S).tar.gz -C <data-root> data
```

**Validate, do not trust the exit code:**

```bash
tar -tzf ~/backup-*.tar.gz >/dev/null && echo OK || echo CORRUPT      # integrity
tar -tzf ~/backup-*.tar.gz | grep -c 'gitea.db'                       # DB present?
tar -tzf ~/backup-*.tar.gz | grep -c 'conf/app.ini'                   # config present?
tar -tzf ~/backup-*.tar.gz | grep -c '/repositories/'                 # repos present?
```

If the archive is missing or fails validation, fix it and redo — you have no backup, so do not proceed.
A valid archive with one skipped subtree is still a usable backup; a green exit code on a half-written
file is not.

## Step 3 — Apply (shortest possible downtime)

```bash
# 1. change the image tag: X.Y.Z → X.Y (auto-follows patches) or pin the exact release
sed -i 's|old-image:X.Y.Z|new-image:X.Y|' docker-compose.yml

# 2. pull while the old container still runs (no downtime yet)
docker compose pull <service>

# 3. recreate — bind-mount data survives; restart is a brief blip
docker compose up -d <service>
```

For a 100 %-consistent physical backup you can `docker stop` → tar → `up -d`, but for an upgrade the
pull-first / recreate sequence is enough and keeps the volume intact.

## Step 4 — Verify

```bash
curl -sS http://<host>:<port>/api/v1/version        # prints the new number
docker ps --filter name=<service> --format "{{.Image}} {{.Status}}"
docker compose logs --tail 25 <service> | grep -iE "error|fail|migrat|listen"
curl -sS http://<host>:<port>/ -o /dev/null -w "HTTP %{http_code}\n"   # the feature you care about
```

## Always-on rules

- **Never write the SSH password** to a file, memory, log, or script. Pass it per-session (an env var
  fed to a small `pty` helper when `sshpass` is not installed) and discard it. Same rule for any API
  token or bearer credential — reference by env name, never the value.
- **Major version = read the breaking changes first.** `x.0` releases usually ship them. Check for
  dependent webhooks, renamed config keys, and deep-linked documents *before* upgrading, and flag them
  to the user. This is a state-changing operation: present order and risk, get explicit go.
- **Match the plan to the real layout, not the assumed one.** Repos may sit in a `repositories/`
  subfolder; per-owner dirs may be symlinks pointing at a path that was later deleted. Verify before you
  act — a broken symlink you "fix" to the wrong target just moves the break.

## Deliver

One results table (version / image / service status / backup location), flag every ⚠️ (breaking
changes, downtime, remaining space). When everything passes, declare success; for any anomaly, give a
concrete next check — do not silently change config to paper over it.
