# Postgres → AWS RDS migration runbook (issue #392)

Phase 2a of the scaling roadmap (#390). Moves Postgres off the shared
`t3.medium` (where it runs beside web/Redis/Sidekiq/staging with **no replica,
no managed backups, no failover**) onto a managed **AWS RDS Multi-AZ** instance.

> **Safety contract.** Every command that reads or writes the **live** database
> is a copy-paste script for a human to run. Nothing in this runbook should be
> executed by an automated agent against prod. Do a full **dump + restore**
> rehearsal against a throwaway target before the real window.

---

## 0. Decision (done)

- **Provider:** AWS RDS for PostgreSQL, **Multi-AZ**, same VPC/region as the
  EC2 box. Chosen over Hatchbox managed PG for failover control + PITR, and over
  Aurora as overkill for current scale (Aurora stays the Phase-2b option).
- **Why RDS:** synchronous standby w/ automated failover, point-in-time
  recovery, private same-VPC networking, RDS Performance Insights to complement
  AppSignal (#391), and a clean read-replica path for later scaling.

---

## 1. Provision spec (you create this in AWS, before the window)

Create the instance and a **dedicated app role** yourself; this runbook assumes
they exist. Recommended settings:

| Setting | Value |
|---|---|
| Engine | PostgreSQL — **match or exceed the current on-box major** (confirm with `SELECT version();` on prod; target PG 16.x unless prod is newer) |
| Class | `db.t4g.medium` (start) — bump to `db.t4g.large` if AppSignal shows DB CPU/headroom pressure |
| Multi-AZ | **Yes** (synchronous standby + auto-failover) |
| Storage | gp3, **storage autoscaling ON**, start ≥ 2× current DB size |
| Encryption at rest | **On** (KMS, default key is fine) |
| VPC | **Same VPC as the EC2 box**; private subnets, **Publicly accessible = No** |
| Security group | New SG allowing inbound **5432 only from the EC2 box's SG** (not 0.0.0.0/0) |
| Backups | Automated, **retention 14 days**, window inside the low-traffic hours |
| Maintenance window | Off-peak, distinct from backup window |
| Performance Insights | On (7-day free tier) |
| Deletion protection | On |
| Parameter group | Custom group cloned from default; set `rds.force_ssl = 1` |

### Roles / credentials to create

The app expects DB name `itty_bitty_boards_production` and connects as a role
whose name + password you control via ENV. Two clean options:

- **Match the existing names** (least surprise): create role `itty_bitty_boards`
  with a strong password; create database `itty_bitty_boards_production` owned by
  it. Then you only need to set `DATABASE_HOST` (+ password) at cutover.
- **New names:** create any role/db you like and set `DATABASE_USERNAME` /
  `DATABASE_NAME` / `ITTY_BITTY_BOARDS_DATABASE_PASSWORD` / `DATABASE_HOST`
  accordingly.

Run these **on the new RDS instance** as the master user (psql connected to the
default `postgres` db). Replace `__STRONG_PASSWORD__`:

```sql
-- creates the app role + database to match config/database.yml defaults
CREATE ROLE itty_bitty_boards WITH LOGIN PASSWORD '__STRONG_PASSWORD__';
CREATE DATABASE itty_bitty_boards_production OWNER itty_bitty_boards;
-- (extensions, if the prod schema uses any — pgcrypto/citext etc. are added
--  later by the restore if they were CREATE EXTENSION'd in the dump)
```

> Keep the RDS **master** credentials too — the restore is easiest run as the
> owner role, but you may need master for `CREATE EXTENSION` on managed PG.

---

## 2. How the app gets repointed (already wired in this branch)

`config/database.yml` `production:` block now reads **all** connection params
from ENV, with fall-throughs equal to today's on-box behavior:

```yaml
database: ENV["DATABASE_NAME"]      || "itty_bitty_boards_production"
username: ENV["DATABASE_USERNAME"]  || "itty_bitty_boards"
password: ENV["ITTY_BITTY_BOARDS_DATABASE_PASSWORD"]
host:     ENV["DATABASE_HOST"]      # unset → nil → local Unix socket (today)
port:     ENV["DATABASE_PORT"]      || 5432
sslmode:  ENV["DATABASE_SSLMODE"]   || "prefer"
```

- **With `DATABASE_HOST` unset → byte-for-byte the current setup.** So this
  change is safe to **deploy days before** the window; it does nothing until you
  set `DATABASE_HOST`.
- **Cutover = set ENV in Hatchbox** (no code change in the window):
  - `DATABASE_HOST` = RDS endpoint (e.g. `speakanyway-prod.abc123.us-east-1.rds.amazonaws.com`)
  - `ITTY_BITTY_BOARDS_DATABASE_PASSWORD` = the app role's RDS password
  - `DATABASE_SSLMODE=require` (RDS; `verify-full` if you add the RDS CA bundle)
  - `DATABASE_USERNAME` / `DATABASE_NAME` only if you chose non-default names
- **Rollback = unset `DATABASE_HOST`** (and revert the password ENV) → next
  boot is back on the local socket. See §7.

> Setting Hatchbox ENV vars triggers a redeploy/restart — that restart is the
> moment the app picks up the new DB. Plan the ENV change as the pivot point of
> the window.

---

## 3. Pre-window prep (no downtime — do this 1–2 days ahead)

1. **Deploy this branch** (the `database.yml` ENV change) to prod. Confirm the
   app is still healthy on the local socket (it must be — `DATABASE_HOST` is
   unset). `curl -sf https://670kd.hatchboxapp.com/up`.
2. **Network check from the EC2 box** — prove it can reach RDS *before* the
   window. SSH to the box and run (replace endpoint):
   ```bash
   # on the prod EC2 box
   nc -vz speakanyway-prod.abc123.us-east-1.rds.amazonaws.com 5432
   # or, if psql is present:
   PGPASSWORD='__STRONG_PASSWORD__' psql \
     "host=speakanyway-prod.abc123.us-east-1.rds.amazonaws.com \
      port=5432 dbname=itty_bitty_boards_production \
      user=itty_bitty_boards sslmode=require" -c 'select version();'
   ```
   If this fails, fix the security group (5432 from EC2 SG) — **do not** start
   the window until it succeeds.
3. **Capture baselines** for the verify step:
   ```bash
   # on the prod EC2 box, against the CURRENT (on-box) DB
   psql -d itty_bitty_boards_production -At -c \
     "select current_setting('server_version');"
   psql -d itty_bitty_boards_production -At -c \
     "select count(*) from users;"
   psql -d itty_bitty_boards_production -At -c \
     "select max(version) from schema_migrations;"
   psql -d itty_bitty_boards_production -At -c \
     "select pg_size_pretty(pg_database_size('itty_bitty_boards_production'));"
   ```
   Write these numbers down — you'll compare them on RDS after restore.
4. **Rehearsal (strongly recommended):** run the full §5 dump+restore into a
   *scratch* db on RDS (e.g. `itty_bitty_boards_rehearsal`) using a recent
   snapshot or a live dump, boot a console against it (§6), then drop the
   scratch db. This times the window and surfaces extension/role issues with
   zero risk.
5. **Confirm the maintenance window** with on-call + update the BetterStack
   monitor note so the `/up` page going briefly down during restart doesn't page
   anyone unexpectedly (or expect the page and ack it).

---

## 4. Downtime window — overview

Low-traffic hours only. Target ordering:

```
T+0   Enter maintenance / stop writers (Sidekiq + web)
T+1   Final dump from on-box Postgres
T+?   Restore into RDS  (bulk of the window; size-dependent)
      Verify row counts + latest migration match baselines
      Set Hatchbox ENV (DATABASE_HOST etc.) → app restarts onto RDS
      Smoke test web + Sidekiq against RDS
T+end Exit maintenance / resume traffic
```

Because Postgres stops accepting writes the moment you stop the app, this is a
**cold** dump/restore (simplest, no logical replication). Window length ≈ dump
time + restore time + verify. Use the rehearsal number to size it.

---

## 5. Cutover — copy-paste scripts (you run these on the prod EC2 box)

> Run as the deploy user on the prod box. These are the live-data steps —
> **a human runs them.** Substitute the RDS endpoint/password placeholders.

### 5a. Stop writers (freeze the source)

```bash
# Stop the app + workers so no new writes land mid-dump.
systemctl --user stop itty-bitty-boards-sidekiq.service
systemctl --user stop itty-bitty-boards-server.service
# (optional) confirm nothing else holds a connection
psql -d itty_bitty_boards_production -At -c \
  "select count(*) from pg_stat_activity where datname='itty_bitty_boards_production' and pid<>pg_backend_pid();"
```

### 5b. Final dump from the on-box DB

```bash
cd /tmp
STAMP=$(date +%Y%m%d-%H%M%S)
DUMP="ibb-prod-${STAMP}.dump"
# custom format (-Fc) → parallel, compressed, restorable with pg_restore
pg_dump -Fc -d itty_bitty_boards_production -f "/tmp/${DUMP}"
ls -lh "/tmp/${DUMP}"
# keep this file until the migration is signed off — it's your fallback source.
```

### 5c. Restore into RDS

```bash
RDS_HOST="speakanyway-prod.abc123.us-east-1.rds.amazonaws.com"
export PGPASSWORD='__STRONG_PASSWORD__'   # app role (or master) password
# --no-owner / --no-acl: RDS has no superuser; let the connecting role own objects.
# Run as the app role so objects are owned by itty_bitty_boards.
pg_restore --no-owner --no-acl --clean --if-exists \
  -h "$RDS_HOST" -p 5432 -U itty_bitty_boards \
  -d itty_bitty_boards_production \
  -j 4 \
  "/tmp/${DUMP}"
# -j 4 = 4 parallel restore jobs; raise if the instance has more vCPU.
# Expect a few harmless NOTICEs (DROP ... IF EXISTS on a fresh db). Investigate
# any real ERROR before proceeding — especially missing extensions (see note).
```

> **Extensions:** if the dump uses `CREATE EXTENSION` (pgcrypto, citext, etc.)
> and the restore errors because the app role can't create them, create them
> once as the **master** user, then re-run the restore:
> ```bash
> PGPASSWORD='__MASTER_PW__' psql -h "$RDS_HOST" -U postgres \
>   -d itty_bitty_boards_production -c 'CREATE EXTENSION IF NOT EXISTS pgcrypto;'
> ```

### 5d. Verify the copy BEFORE repointing (compare to §3 baselines)

```bash
RDS_HOST="speakanyway-prod.abc123.us-east-1.rds.amazonaws.com"
export PGPASSWORD='__STRONG_PASSWORD__'
PSQL="psql -h $RDS_HOST -U itty_bitty_boards -d itty_bitty_boards_production -At"
$PSQL -c "select count(*) from users;"
$PSQL -c "select max(version) from schema_migrations;"
$PSQL -c "select count(*) from boards;"
$PSQL -c "select count(*) from credit_transactions;"
$PSQL -c "select pg_size_pretty(pg_database_size('itty_bitty_boards_production'));"
```

**Gate:** counts + latest migration must match the §3 baselines. If they don't,
**stop** — do not repoint; troubleshoot or roll back (the on-box DB is still
intact and untouched by the restore).

### 5e. Repoint the app (Hatchbox ENV — the pivot)

In the Hatchbox dashboard (or API) for the **production** app, set:

```
DATABASE_HOST                       = <RDS endpoint>
ITTY_BITTY_BOARDS_DATABASE_PASSWORD = <app role RDS password>
DATABASE_SSLMODE                    = require
# only if you used non-default names:
# DATABASE_USERNAME = <role>
# DATABASE_NAME     = <db>
```

Applying these restarts the app onto RDS. (If you set them via the Hatchbox API,
use the env-var templates in auto-memory `hatchbox-env-vars.md`.)

### 5f. Restart workers + smoke test

```bash
systemctl --user start itty-bitty-boards-server.service
systemctl --user start itty-bitty-boards-sidekiq.service
# health
curl -sf https://670kd.hatchboxapp.com/up && echo OK
# prove the app is actually on RDS (host should be the RDS endpoint, NOT empty)
cd /home/deploy/itty-bitty-boards/current   # adjust to the Hatchbox app path
RAILS_ENV=production bin/rails runner \
  'c = ActiveRecord::Base.connection_db_config.configuration_hash; \
   puts "host=#{c[:host].inspect} db=#{c[:database]} user=#{c[:username]}"; \
   puts ActiveRecord::Base.connection.select_value("select inet_server_addr()")'
```

Then run §6 verify. Once green, **exit maintenance** and resume normal traffic.

---

## 6. Verify checklist (app + Sidekiq healthy on RDS, backups confirmed)

- [ ] `GET /up` returns 200 (web up on RDS).
- [ ] Rails console confirms `connection host = RDS endpoint` (the runner in §5f).
- [ ] **Reads:** load a board / sign-in page; `User.count` matches baseline.
- [ ] **Writes:** create + delete a throwaway record through the app, or
      `bin/rails runner 'u=User.last; u.touch; puts u.updated_at'` — confirms the
      app role has write perms on RDS.
- [ ] **Sidekiq:** enqueue a trivial job and watch it run —
      `bin/rails runner 'DiskSpaceAlertJob.perform_async'` then
      `bin/prod-logs worker` shows it executing against RDS (no connection errors).
- [ ] **Migrations:** `bin/rails db:migrate:status | tail` shows all `up`,
      latest version == baseline.
- [ ] **AppSignal:** prod still reporting; DB query traces now point at RDS;
      no spike in errors after cutover.
- [ ] **No leftover connections to the old on-box DB** (let it idle a few hours
      before decommissioning — it's your rollback source).
- [ ] **Backups confirmed on RDS:**
  - [ ] RDS console → instance → Maintenance & backups: automated backups **On**,
        retention = 14 days, a snapshot exists (the create-time snapshot, plus
        the first scheduled one after the window).
  - [ ] **Restore drill:** restore the latest automated snapshot into a temporary
        instance (`...-restore-test`), connect, `select count(*) from users;`,
        then delete that temp instance. A backup you haven't restored is a
        hope, not a backup.
  - [ ] (Optional) take a **manual snapshot** named `pre-go-live-<date>` and
        keep it past the automated retention as a known-good baseline.

---

## 7. Rollback plan

The on-box Postgres is **never modified** by this procedure — the dump is
read-only and the restore targets RDS. So rollback is fast and lossless **as
long as you roll back before accepting writes on RDS**.

### Case A — problem found BEFORE repointing (during §5c–5d restore/verify)
Nothing happened to prod yet. Restart the app on the local socket and abort:
```bash
systemctl --user start itty-bitty-boards-server.service
systemctl --user start itty-bitty-boards-sidekiq.service
curl -sf https://670kd.hatchboxapp.com/up && echo "back on on-box DB"
```
Investigate offline; reschedule the window.

### Case B — problem found AFTER repointing but writes are negligible/recoverable
1. In Hatchbox, **unset `DATABASE_HOST`** (and revert `ITTY_BITTY_BOARDS_DATABASE_PASSWORD`
   to the on-box password, and unset `DATABASE_SSLMODE`/`DATABASE_USERNAME`/`DATABASE_NAME`
   if set). Apply → app restarts back onto the on-box socket.
2. Confirm: the §5f runner should show `host=nil`/empty (local socket) again.
3. `curl -sf .../up`. You're back on the original DB exactly as before cutover.
4. **Reconcile writes:** any rows written to RDS between §5e and rollback are not
   on the on-box DB. If the window was truly quiet (app freshly restarted, low
   traffic) this is usually empty; if not, export the delta from RDS and replay,
   or treat as the trigger to redo the cutover rather than roll back.

> **Decision rule:** the longer RDS has served live writes, the more painful a
> roll *back* becomes. Prefer rolling **forward** (fix on RDS) once real user
> writes have accumulated. Keep the window short and verify fast to keep Case B
> cheap.

### Decommission (only after sign-off)
Leave the on-box Postgres running and untouched for **at least 24–48h** after a
clean cutover. Once confident: stop the on-box Postgres service, reclaim its disk
(this also relieves the disk-pressure problem the DiskSpaceAlertJob watches), and
update monitoring. **Do not** delete the final dump (`/tmp/ibb-prod-*.dump`) or
the `pre-go-live` snapshot until the migration is fully signed off.

---

## 8. Post-migration follow-ups (not in this window)

- Add the RDS CA bundle to the box and move to `DATABASE_SSLMODE=verify-full`.
- Wire RDS CloudWatch alarms (CPU, free storage, connections, replica lag) +
  consider an AppSignal/BetterStack integration for DB alerts.
- Phase 2b: add a **read replica** and route read-heavy queries.
- Revisit instance sizing once AppSignal has a week of post-cutover DB metrics.
- Move Redis off the shared box (next roadmap item) now that PG has set the
  managed-service pattern.
```

