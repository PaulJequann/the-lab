# Services Data Consolidation (Postgres + Redis)

## Context

The lab currently runs three separate Proxmox LXCs hosting stateful services for k8s-deployed applications:

| LXC              | IP          | Hosts                          | Consumed by               |
| ---------------- | ----------- | ------------------------------ | ------------------------- |
| `glitchtip-data` | 10.0.10.83  | PostgreSQL 14                  | Glitchtip (k8s)           |
| `infisical-data` | 10.0.10.85  | PostgreSQL 14 + Redis 6.0.16   | Infisical (k8s)           |
| `honcho`         | 10.0.10.84  | PostgreSQL 14 + Redis (local)  | Honcho app (same LXC)     |

Each LXC is provisioned by its own Ansible role (`glitchtip_data`, `infisical_data`) that
duplicates ~90% of the same logic: PG cluster discovery, pg_hba CIDR allow-list, user/DB
provisioning, systemd backup timer, NFS backup mount. Glitchtip and Infisical each run a
single tiny database (~100-130MB). The duplication is the real pain — not the isolation.

The goal is to **consolidate Glitchtip and Infisical's stateful dependencies onto a single
new LXC** (`services-data`, 10.0.10.86), driven by a single generic Ansible role, leaving
Honcho untouched because its Postgres + Redis are intentionally co-located with the
Honcho app itself on the `honcho` LXC.

## Why LXC, not in-cluster Postgres (e.g., CNPG)

Considered and rejected. k3s cluster inventory:
- 3 control-plane nodes (Lenovo M73), 4C / 7.6GB each, already at ~45% memory utilization
- 2 worker nodes (Surface), 8C / 15.6GB each
- Storage classes: `fast-local` (rancher.io/local-path, node-pinned) and `nfs-csi`
  (TrueNAS-backed NFS, poor fit for Postgres WAL/fsync)

No distributed block storage (no Longhorn, Rook/Ceph, OpenEBS). CNPG would either pin
Postgres to one worker (SPOF) or require standing up Longhorn, which is a separate
infrastructure project. The LXC approach maps cleanly onto Proxmox local/ZFS storage
and sidesteps the whole k8s-storage-for-stateful-workloads question. The principle is:
**stateful workloads live on LXCs until the cluster has storage to host them properly.**

## Why Redis goes on the new LXC too

Infisical's Redis is currently on `infisical-data`. Glitchtip previously used a Redis
on `glitchtip-data` but was migrated in commit `ed5b8c4` to an in-cluster Valkey —
**not** for architectural reasons, but because Ubuntu 22.04's apt Redis is 6.0.16 and
Glitchtip 6.0.10's worker requires `BLMOVE` (Redis 6.2+). That migration is a
version-workaround, not a precedent. Infisical runs happily on 6.0.16, so it follows the
stateful-on-LXC rule. Glitchtip's in-cluster Valkey stays as-is.

## Key Decisions

| #   | Decision                     | Resolution                                                                                                                     |
| --- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| 1   | Postgres version             | PostgreSQL 17 installed via PGDG apt repo on Ubuntu 22.04 LXC. Existing pattern: Honcho role already uses PGDG fallback.        |
| 2   | Install path                 | LXC (not VM, not in-cluster). No Proxmox upgrade required — PGDG supports PG12-17 on jammy.                                    |
| 3   | LXC resources                | 2 cores / 2GB RAM / 30GB disk on `local-lvm`. Bump from existing 1GB; room for `shared_buffers` tuning and future apps.        |
| 4   | Proxmox node                 | `mia` (matches existing service LXC placement, separate from k3s cluster nodes).                                                |
| 5   | IP address                   | 10.0.10.86 (next free in the `.83-.85` service LXC range).                                                                     |
| 6   | LXC name                     | `services-data` — scope-neutral, accommodates Postgres + Redis + future stateful services.                                      |
| 7   | Redis                        | Infisical's Redis moves to `services-data` (Ubuntu 22.04 apt, 6.0.16). Glitchtip's in-cluster Valkey stays untouched.          |
| 8   | Honcho                       | **Not in scope.** Honcho's Postgres + Redis + app are intentionally co-located on the `honcho` LXC. No change.                 |
| 9   | pg_hba allow-list            | `10.0.10.0/24` (node_network) — matches current behavior. Per-DB tightening is theater without VLAN segmentation.              |
| 10  | PgBouncer                    | **No.** Default `max_connections = 100` is plenty for 2 apps. Add only if `too many connections` errors appear in practice.    |
| 11  | pgvector                     | **Do not pre-install.** Neither Glitchtip nor Infisical uses it. Per-DB `extensions` field triggers `postgresql-17-pgvector` install on demand. |
| 12  | Glitchtip data migration     | **Dump/restore** (not start-fresh). 104MB takes 2 seconds; preserves DSN keys so no app-side secret rotation.                  |
| 13  | Infisical rehearsal          | **Full rehearsal required** — dump → restore → boot scratch Infisical against new DB → verify it can decrypt secrets.          |
| 14  | Backups                      | **Deferred to separate project.** Current state is already backup-less; consolidation slightly increases blast radius.         |
| 15  | Old LXC decommission timing  | Stop at cutover, destroy after 7 days. Calendar reminder to prevent drift.                                                     |
| 16  | Ansible role name            | `services_data` — replaces `glitchtip_data` and `infisical_data` with a single input-driven role.                              |

## Risk Flagged

**Backups remain disabled on the consolidated LXC until the separate backup project
completes.** Both existing LXCs have `glitchtip_backup_enabled: False` and
`infisical_backup_enabled: False` today — the systemd backup timer/script is implemented
but not activated. Consolidating onto one LXC changes blast radius from
"one failure → one app down" to "one failure → two apps down." Not a blocker per user
decision, but tracked as a risk.

## Architecture After Migration

```
Proxmox node "mia"
├── services-data (10.0.10.86)        NEW
│   ├── PostgreSQL 17 (PGDG)
│   │   ├── glitchtip DB
│   │   └── infisical DB
│   └── Redis 6.0.16 (infisical)
├── honcho (10.0.10.84)               UNCHANGED
│   ├── PostgreSQL 14 + pgvector (localhost)
│   ├── Redis (localhost)
│   └── Honcho API + deriver systemd services
├── glitchtip-data (10.0.10.83)       DESTROYED (day 7 post-cutover)
└── infisical-data (10.0.10.85)       DESTROYED (day 7 post-cutover)

k3s cluster
├── glitchtip namespace
│   ├── Glitchtip web/worker/beat   → services-data:5432/glitchtip
│   └── chart-bundled Valkey          UNCHANGED
└── infisical namespace
    └── Infisical pods              → services-data:5432/infisical
                                    → services-data:6379 (Redis)
```

## Implementation Phases

### Phase 1 — Generic `services_data` role + provision new LXC

**Goal:** `services-data` LXC exists, runs empty PG17 + Redis, accepting connections.
No production traffic yet.

**Prerequisites (before step 1):**

- Add a `services-data` entry to `config.yaml` `terraform_service_lxcs` dict (mirror the
  `infisical-data` shape: `target_node`, `hostname`, `ip`, `gateway`, `storage`,
  `disk_size`, `cores`, `memory_mb`, `swap_mb`, `nameserver`; plus `postgres` / `redis`
  sub-keys for role-input defaults).
- Add `services-data` to `templates/ansible/inventory/hosts.yaml.j2` using the
  `terraform_service_lxcs['services-data']` dict pattern (matching the existing
  `infisical-data` entry — do **not** use the flat-var pattern that `glitchtip-data` uses).
- Run `task configure` to regenerate `ansible/` and `terraform/` consuming files.
- Export the Ansible Infisical machine identity (`INFISICAL_CLIENT_ID`,
  `INFISICAL_CLIENT_SECRET`) plus `INFISICAL_DB_PASSWORD` and `INFISICAL_REDIS_PASSWORD`
  in the shell that will run the new `services-data.yml` playbook. The client ID/secret
  are required by the `infisical.vault.read_secrets` lookup used below to fetch
  Glitchtip's DB password (same lookup pattern as `glitchtip-data.yml` and `honcho.yml`);
  the DB/Redis passwords cover the Infisical-hosted secrets that can't be sourced from
  Infisical itself (chicken-and-egg, since the LXC provisioned here hosts Infisical's DB
  and Redis). The simplest path is to run
  `source scripts/load-bootstrap-secrets.sh ansible` — it loads all four from the
  `bootstrap` rbw profile in one step.

1. Create `terraform/services-data/main.tf` by copying `terraform/infisical-data/main.tf`:
   - `hostname = "services-data"`
   - `ip_address = "10.0.10.86"`
   - `cores = 2`, `memory = 2048`, `disk_size = "30G"`
   - `target_node = "mia"`, `storage = "local-lvm"`
2. Create new Ansible role `ansible/roles/services_data/` with inputs:
   - `services_data_postgres_version: 17`
   - `services_data_postgres_listen_addresses: 'localhost,{{ services_data_ip }}'`
   - `services_data_postgres_databases: []` — list of `{name, user, password, allowed_cidrs, extensions}`
   - `services_data_redis_enabled: true`
   - `services_data_redis_bind: '127.0.0.1 {{ services_data_ip }}'`
   - `services_data_redis_port: 6379`
   - `services_data_redis_password: <from env var INFISICAL_REDIS_PASSWORD>` — must **not**
     be fetched from Infisical (chicken-and-egg: this LXC hosts the Redis that Infisical
     depends on, so Infisical may be unavailable when you need to re-apply this role)
   - `services_data_redis_appendonly: yes`

   **Secret sourcing in the `services-data.yml` playbook (critical):** the new playbook
   must dual-source, following the existing split:
   - Glitchtip DB password → `infisical.vault.read_secrets` lookup at `/kubernetes/glitchtip`
     (pattern from `templates/ansible/playbooks/glitchtip-data.yml.j2`).
   - Infisical DB password → `lookup('env', 'INFISICAL_DB_PASSWORD')`
     (pattern from `templates/ansible/playbooks/infisical-data.yml.j2`).
   - Infisical Redis password → `lookup('env', 'INFISICAL_REDIS_PASSWORD')`.

   Never source Infisical's own credentials from Infisical.

3. Role tasks:
   - Install nfs-common, python3-psycopg2
   - Install PGDG prerequisites (`gnupg`, `lsb-release`), fetch signing key, add PGDG apt
     repo **unconditionally** before any postgresql package. (Borrow only the apt-key /
     apt_repository tasks from `templates/ansible/roles/honcho/tasks/main.yaml.j2` — the
     honcho wrapping conditional is a pgvector-availability fallback, not a pattern for
     a PG17 install, so it does not carry over.)
   - Install `postgresql-17`, `postgresql-client-17` with pinned versions. Do **not**
     pre-install `postgresql-17-pgvector` at the role level — per-DB consumers that need
     it declare it in their `extensions` field, which triggers `apt install
     postgresql-17-pgvector` on demand (neither Glitchtip nor Infisical use pgvector
     today).
   - Skip `pg_lsclusters` discovery; set `services_data_postgres_version: 17` as a static
     fact. Assert the installed package version matches before proceeding.
   - Configure `listen_addresses`, pg_hba with `managed_databases` loop (lift from
     `templates/ansible/roles/glitchtip_data/tasks/main.yaml.j2:58-143`)
   - Create roles + databases per `services_data_postgres_databases`
   - Enable extensions per-DB from the `extensions` field. Do **not** derive the apt
     package name by string-concatenating `postgresql-17-<ext>` — extension names and
     package names diverge. Maintain an explicit extension→package map in the role
     (seed it with the cases we actually need) and fail loudly on an unmapped
     extension. Known mappings:
     - `vector` → `postgresql-17-pgvector` (extension name is `vector`, per
       `CREATE EXTENSION vector` in the existing Honcho role; package is `pgvector`)
     - Contrib extensions that ship with `postgresql-17` (`pg_trgm`, `hstore`, `uuid-ossp`,
       `citext`, etc.) → no package install required; just `CREATE EXTENSION`
   - Install Redis 6.0.16 from Ubuntu apt, configure bind/port/password/appendonly
   - **No backup timer/script** (deferred — leave the hooks in the role disabled by default)
4. Provision the LXC: `terraform apply` on new module
5. Apply role with empty `services_data_postgres_databases` — verifies PG17 + Redis start and reject unauthenticated connections
6. Smoke test: `psql -h 10.0.10.86 -U postgres` from a service LXC, `redis-cli -h 10.0.10.86 -a <pw> ping`

**Exit criteria:** Empty `services-data` LXC running, PG17 and Redis 6.0.16 reachable on the LAN.

### Phase 2 — Glitchtip cutover

**Goal:** Glitchtip running against `services-data`. Old `glitchtip-data` still running as fallback.

1. Add Glitchtip to `services_data_postgres_databases`:
   ```yaml
   - name: glitchtip
     user: glitchtip
     password: <from Infisical>
     allowed_cidrs: [10.0.10.0/24]
     extensions: []
   ```
2. Re-run role → Glitchtip DB created empty.
3. On old `glitchtip-data`: `pg_dump -Fc -d glitchtip -f /tmp/glitchtip.dump`
4. Transfer to `services-data` and restore: `pg_restore -d glitchtip -U glitchtip /tmp/glitchtip.dump`
5. Verify row counts match between old and new (e.g., `SELECT count(*) FROM auth_user` on both).
6. Update the `DB_HOST` raw secret in Infisical (project `the-lab`, env `prod`, path
   `/kubernetes/glitchtip`) from `glitchtip-data` (or `10.0.10.83`) to `services-data`
   (or `10.0.10.86`). The `glitchtip-secrets` InfisicalSecret composes `DATABASE_URL` and
   `MAINTENANCE_DATABASE_URL` at operator reconcile time (every 60s) from raw components
   (`DB_HOST`, `DB_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`) — the YAML
   manifest at `kubernetes/apps/glitchtip/templates/secrets/glitchtip.infisicalsecret.yaml`
   itself does **not** need to change. Verify with:
   `kubectl get secret glitchtip-secrets -n glitchtip -o jsonpath='{.data.DATABASE_URL}' | base64 -d`
7. ArgoCD rolls Glitchtip pods (force pickup with `kubectl rollout restart deploy -n glitchtip`
   if the Secret projector doesn't auto-restart). Confirm: UI loads, existing user can log
   in, send a test Sentry event via curl and confirm it lands in the DB.
8. **Rollback path:** revert the `DB_HOST` value in Infisical back to `glitchtip-data`
   (or `10.0.10.83`). The operator re-composes connection strings within 60s; restart
   Glitchtip pods. Old LXC still running.

**Exit criteria:** Glitchtip serving traffic from `services-data`, test event ingested, rollback path confirmed working.

### Phase 3 — Infisical rehearsal (no production cutover)

**Goal:** Prove the Infisical restore path works end-to-end on a scratch deployment before
touching production. This is the DB that holds every secret in the cluster.

1. Add Infisical to `services_data_postgres_databases` (same shape as Glitchtip).
2. `pg_dump -Fc -d infisical` from `infisical-data` → transfer → restore into `services-data:infisical`.
3. Deploy a scratch Infisical in an `infisical-rehearsal` namespace pointed at
   `services-data` for **both** Postgres and Redis (scratch namespace, scratch Helm
   release). The rehearsal explicitly exercises the LXC Redis path — do **not** fall
   back to the chart-built-in Redis; the point is to verify end-to-end cutover wiring
   before touching production.
4. Verify the rehearsal Infisical:
   - Pods come up healthy, no decryption errors in logs
   - Can log in as the existing admin user
   - Can read an existing secret via API
   - Can write a new secret and read it back
5. Tear down scratch namespace once validated.
6. Drop the rehearsal data from `services-data:infisical` (we'll re-dump at real cutover time).

**Exit criteria:** Demonstrated that a dump from production restores cleanly and Infisical boots against it with full secret decryption working.

**Status 2026-04-25:** Completed. `task phase3-infisical-rehearsal` converged
`services-data`, restored a fresh `infisical-data` dump into `services-data:infisical`,
and deployed the scratch `infisical-rehearsal` Helm release pointed at
`10.0.10.86` for both Postgres and Redis. Verification passed:
- Scratch pod rolled out healthy and `/api/status` returned 200.
- Logs showed successful Postgres and Redis connections; Redis 6.0.16 produced the
  expected "minimum Redis 6.2.0 recommended" warning but did not block startup.
- Existing restored secrets decrypted: the Ansible machine identity read 13 secrets
  from `/kubernetes/glitchtip`.
- Admin identity write/read/delete probe succeeded against the restored rehearsal DB.
- `task phase3-infisical-rehearsal-cleanup` removed the scratch namespace and recreated
  an empty `services-data:infisical` DB for the future production cutover dump.

### Phase 4 — Infisical production cutover

**Goal:** Production Infisical running against `services-data`. Old `infisical-data` still running as fallback.

1. Scale Infisical deployment to 0 (stops writes — brief outage; every InfisicalSecret reconciliation halts during this window, so pick a quiet time).
2. Fresh `pg_dump -Fc -d infisical` from `infisical-data`.
3. Drop and recreate the `infisical` DB on `services-data` (clean slate), then `pg_restore`.
4. Update the Taskfile-managed bootstrap Secrets that Infisical itself reads (Infisical
   cannot bootstrap from itself — see `kubernetes/infrastructure/infisical/values.yaml`
   and `docs/plans/secret-management-redesign.md:726-768` for the current flow):
   a. **Refactor the host source first (do this before Phase 4 begins).** The
      `infisical-postgres-connection` (key: `connectionString`) and `infisical-secrets`
      (key: `REDIS_URL`) Secrets are composed by the `apply-infisical-bootstrap-secrets`
      task in `Taskfile.yml`, and the host is currently a **hardcoded literal**:
      ```yaml
      vars:
        INFISICAL_NS: infisical
        INFISICAL_DATA_IP: 10.0.10.85       # Taskfile.yml:~301
      ```
      It is **not** sourced from `config.yaml` or Bitwarden — updating either of those
      alone will not repoint Infisical. Refactor the Taskfile to pull the host from a
      single source of truth before cutover. Two acceptable options:
      - **Option A (preferred):** promote the IP to `config.yaml` (e.g.,
        `infisical_db_host: 10.0.10.86` under `services_data`), template it into
        `Taskfile.yml.j2`, and regenerate via `task configure`. This keeps the value
        reviewable in git alongside the rest of the consolidation change.
      - **Option B:** change the literal in `Taskfile.yml` directly as part of the
        Phase 4 commit. Cheaper, but leaves the value hardcoded in two places long-term
        (both LXC IPs in `config.yaml` and one in the Taskfile).

      Confirm the post-composition shape will be:
      - `postgresql://infisical:${INFISICAL_DB_PASSWORD}@10.0.10.86:5432/infisical?sslmode=disable`
      - `redis://:${INFISICAL_REDIS_PASSWORD}@10.0.10.86:6379`
   b. With the new host in place, re-run the bootstrap flow:
      `task apply-infisical-bootstrap-secrets` (pulls `INFISICAL_DB_PASSWORD` and
      `INFISICAL_REDIS_PASSWORD` from `rbw`, re-applies both Secrets). Verify with:
      - `kubectl get secret infisical-postgres-connection -n infisical -o jsonpath='{.data.connectionString}' | base64 -d`
      - `kubectl get secret infisical-secrets -n infisical -o jsonpath='{.data.REDIS_URL}' | base64 -d`
   c. `kubectl rollout restart deployment -n infisical` to force Infisical pods to
      re-read the updated Secrets (`envFrom` does not watch for Secret changes).
5. Scale Infisical back to full replicas.
6. Verify:
   - Login works
   - Existing InfisicalSecret resources in cluster are still reconciling (check operator logs)
   - `kubectl get infisicalsecret -A` — all `Ready: True`
   - Write a new secret in Infisical UI, confirm it propagates to a test InfisicalSecret
7. **Rollback path:** scale Infisical to 0, flip connection strings back, scale up. Original data on `infisical-data` is untouched because we only read from it.

**Exit criteria:** Production Infisical healthy on `services-data`, all InfisicalSecrets still reconciling, rollback path confirmed.

**Status 2026-04-25:** Completed. Production Infisical was scaled to zero, a fresh
`infisical-data` dump was restored into `services-data:infisical`, and the bootstrap
Secrets were repointed to `10.0.10.86` for both Postgres and Redis. Verification passed:
- Production `infisical-postgres-connection` and `infisical-secrets` now resolve to
  `10.0.10.86` (values verified with credentials redacted).
- Infisical deployment rolled back up to 1/1 Ready and `/api/status` returned 200.
- Startup logs showed successful Postgres and Redis connections.
- Machine identity read 13 restored secrets from `/kubernetes/glitchtip`.
- Admin identity write/read/delete probe succeeded against the production restored DB.
- `/canary` write propagated through the Infisical operator into the managed
  `infisical-canary/canary-heartbeat` Kubernetes Secret, then the probe key was deleted
  and removed from the managed Secret.
- All `InfisicalSecret` resources reported `LoadedInfisicalToken=True`,
  `ReadyToSyncSecrets=True`, and `AutoRedeployReady=True`; operator logs showed
  successful syncs for canary, ArgoCD, cert-manager, Deeptutor, and Glitchtip.
- The original `infisical-data:infisical` database was left intact with the same table
  count as the restored target, so rollback remains a Secret host flip plus pod restart.

### Phase 5 — Cleanup

**Goal:** Repo state reflects new architecture. Old infrastructure destroyed after cooling period.

**Day 0 (cutover day):**
1. Stop (do not destroy) `glitchtip-data` and `infisical-data` LXCs from Proxmox UI / terraform.
2. Set calendar reminder for Day 7.
3. Delete `ansible/roles/glitchtip_data/` and `ansible/roles/infisical_data/`.
4. Delete `templates/ansible/roles/glitchtip_data/` and `templates/ansible/roles/infisical_data/` sources.
5. Delete `ansible/playbooks/glitchtip-data.yml` and `infisical-data.yml` (and templates).
6. Remove `glitchtip_*` and `infisical_postgres_*`, `infisical_redis_*` variables from
   `templates/ansible/group_vars/services.yaml.j2`.
7. Keep `glitchtip_data_ip` / `infisical_data_ip` variables in `config.yaml` intact for
   now. Also keep the prior Infisical bootstrap host value reachable: if Phase 4 used
   Option A (host sourced from `config.yaml`), leave the old `10.0.10.85` noted in a
   commented line or a dedicated `infisical_db_host_rollback` var so the rollback is a
   single-value flip; if Option B (literal Taskfile edit), leave the prior value in the
   Phase 4 commit message and the git history is the rollback source. Rationale: the
   Infisical rollback path is "flip the bootstrap host back and re-run
   `task apply-infisical-bootstrap-secrets`"; losing the old value makes that slower.
   `glitchtip_data_ip` is no longer load-bearing post-cutover (Glitchtip rollback is an
   Infisical `DB_HOST` value revert, not a repo variable), but keep it for safety until
   Day 7. Neither variable is referenced by any InfisicalSecret.
8. Run `task configure` to regenerate `ansible/` from templates.
9. Commit: `feat(services-data): consolidate Glitchtip + Infisical onto shared LXC`.

**Day 7 (post-cooling):**
1. Destroy old LXCs: `terraform destroy` on `terraform/glitchtip-data/` and `terraform/infisical-data/`.
2. Delete those terraform modules.
3. Remove the remaining `glitchtip_data_*` / `infisical_data_*` config.yaml entries.
4. Final `task configure` + commit: `chore: remove decommissioned glitchtip-data and infisical-data LXCs`.

**Exit criteria:** Repo contains no references to old LXCs. One `services_data` role. One
terraform module. Two LXCs destroyed.

## Validation Gates

Each phase must pass these before moving on:

- **Phase 1:** `psql` and `redis-cli` connectivity from a service LXC
- **Phase 2:** Glitchtip UI login + test event end-to-end, rollback tested
- **Phase 3:** Scratch Infisical successfully decrypts production secrets
- **Phase 4:** All `InfisicalSecret` resources `Ready: True`, new secret write propagates
- **Phase 5:** `task configure` + `ansible-lint` + ArgoCD health all clean

## Out of Scope

- **Backups** — tracked as separate project. Do not block this work on it.
- **Honcho migration** — Honcho's co-located architecture is intentional and working.
- **Proxmox upgrade** — overdue but unrelated. Do not couple to this project.
- **Glitchtip Redis/Valkey changes** — in-cluster Valkey stays as-is.
- **PgBouncer / connection pooling** — add only if connection exhaustion is observed.

## References

- Current duplicated role: `templates/ansible/roles/glitchtip_data/tasks/main.yaml.j2` (managed_databases pattern at lines 58-143)
- PGDG pattern: `templates/ansible/roles/honcho/tasks/main.yaml.j2` (pgvector install fallback logic)
- Glitchtip Valkey migration rationale: commit `ed5b8c4` (BLMOVE / Redis 6.2+ requirement)
- Terraform LXC module: `terraform/modules/proxmox-lxc-service`
- Existing terraform instances to copy: `terraform/infisical-data/main.tf`
