# Case: Upgrading a self-hosted ForgeJo over SSH broke nothing — but nearly left no backup

**Service:** ForgeJo 16.0.4 → 17.0.1 (`codeberg.org/forgejo/forgejo`), single `docker-compose`
service, bind-mounted data volume · **Access:** SSH with a password-bearing service account (no
sudo) · **Date:** 2026-11-08
**Full write-up:** [`write-up.md`](write-up.md) (Chinese, with the exact commands)

## Context

A self-hosted ForgeJo ran on a LAN host as one `docker-compose` service with a bind-mounted data
volume. The job was a plain "update to the latest image." It stayed plain until the backup step: the
obvious backup location was not writable by the SSH user, and one obvious data subtree was not
readable by it either.

## What I measured before changing anything

- One service `forgejo`, image pinned to `16.0.4`, ports `3000` (web) + `2222`→`22` (ssh).
- Data volume is a host bind-mount at `/data/forgejo/data:/data`. The DB is **SQLite** (`gitea.db`),
  not an external postgres — so the entire instance lives in that one directory.
- The real git repos live in `git/repositories/` (a subfolder, **not** the default `git/repos`), and
  the per-owner directories are **symlinks** pointing at `/data/git/repositories/<owner>` — a path
  that no longer existed. All six were already broken before this task.
- `/data/forgejo` is owned by `root` (the SSH user could not write there); the subtree worth backing
  up, `git/`, was owned by the SSH user.

## The two traps

1. **The backup location was a permission minefield.** Writing the tar to the "obvious" place failed
   because that directory was root-owned; and a live `tar` of the volume tripped on one root-`700`
   subtree (`data/ssh`) the SSH user could not read. `tar` exited non-zero, which *looks* like "no
   backup." The fix was to point the archive at a writable path and skip the one unreadable subtree —
   the archive was still valid. Validated with `tar -tzf` + grep for the DB and `app.ini`, **not** by
   exit code.
2. **The plan had to match the real layout.** The owner symlinks pointed at a deleted path, so each
   was rebuilt to the real `git/repositories/<owner>` rather than assuming where repos lived.

## Fix

- Backed up the whole volume to a writable path (skipping the unreadable `data/ssh` subtree): a valid
  archive containing all 31 repos, `gitea.db`, and `app.ini`. Freed nothing yet — see below.
- Repointed the six broken owner symlinks to the real repository directories. All resolve; reachable
  repo count unchanged at 31.
- Changed the compose image tag `16.0.4` → `17.0`, `docker compose pull` (old container still ran),
  then `docker compose up -d`. DB migrations ran clean; web returns HTTP 200 on 17.0.1. The stale
  252 MB dump left in the volume was removed (~241 MB freed).

## Lessons

Codified in [playbook 0008](../../playbooks/0008-maintain-self-hosted-docker-over-ssh.md) (the
check→backup→apply→verify method, with the backup-permission rule as the centerpiece) and added to
the [handoff](../../handoff.md) "Traps" list.

⚠️ **Breaking changes on the way up:** 17.0 changed the base of absolute links in rendered documents
(repo root instead of instance root) and deprecated the Action-run webhook events (migrate by hand to
workflow run events). Neither touched this instance, but they are exactly the kind of thing to check —
any external webhook receiver or deep-linked document — before upgrading a major version.
