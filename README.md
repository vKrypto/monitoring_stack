# monitoring_stack

Source of truth for the Swarm stack `monitoring_stack` on the Proxmox VM
(`192.168.100.10`), copied from `/data/stacks/monitoring` on 2026-09-20, and for the services the
Proxmox hypervisor (`192.168.100.4`) and that VM run outside Docker ([`host/`](#host-services-outside-docker)).

| Service | Port on the VM | Notes |
|---|---|---|
| Grafana | 10000 | dashboards provisioned from `grafana-provisioning/` |
| Graylog | 10001 (UI), 10002/udp and 12201/udp (GELF) | UI is also fronted at `http://graylog.local.internal/` by the VM's `proxy_stack` |
| Portainer | 10003 (https) | |
| Filebrowser | 10004 | read-only view of `/data/stacks` |
| GlitchTip | 10005 | error tracking shared by every project; see below |
| Prometheus, node-exporter, cAdvisor, OpenSearch, MongoDB, GlitchTip's Postgres/Redis/worker/postgres-exporter | internal only | overlay network `monitoring_stack_monitoring` |

## Deploy

```bash
cp .env.example .env      # first time only, then fill it in
./deploy.sh --dry-run     # read-only: checks + what would change
./deploy.sh               # create data dirs, apply host/, copy config, docker stack deploy
```

`deploy.sh` needs the ssh aliases `docker-vm` (ubuntu, passwordless sudo) and `proxmox` (root on the
hypervisor), and a Swarm manager with `vm.max_map_count >= 262144` (OpenSearch) and `/data/docker`
present (cAdvisor). It checks all of this and prints the fix if something is off.

## GlitchTip (error tracking for all projects)

Sentry-compatible. The image is pinned to the exact digest it ran as in `job_seeker_stack` (6.2.6);
change the digest in `docker-compose.yml` to upgrade.

- **Login:** `GLITCHTIP_ADMIN_EMAIL` / `GLITCHTIP_ADMIN_PASSWORD` from `.env`. `glitchtip_migrate`
  creates the admin and re-syncs its password on every deploy, so rotating the password is: edit
  `.env`, run `./deploy.sh`. Open signup is off (`ENABLE_USER_REGISTRATION=false`); the admin creates
  organizations, projects and invites.
- **Connect a project:** create it in the UI, then *Project Settings -> Client Keys (DSN)*. Use the DSN
  as that project's `SENTRY_DSN`, e.g. `http://<key>@192.168.100.10:10005/<project_id>`. Containers on
  the VM can use the IP form or, once it exists, `glitchtip.local.internal`. The frontend DSN is baked
  into the browser bundle, so it must be a name or IP a browser can reach.
- **Data:** Postgres in `data/glitchtip-db` (bind mount, not in git). The DB password in `.env` must
  match the one stored in an existing data dir.
- **Moved from job-seeker:** `scripts/migrate-glitchtip-from-job-seeker.sh` (one-time, dry-run by default)
  backs up the DB, removes the old services from `job_seeker_stack`, copies the data dir here and
  verifies the login. Merge the job-seeker change that drops GlitchTip from its stack files before the
  next job-seeker deploy.
- **Friendly name:** `glitchtip.local.internal` needs a Pi-hole DNS record (192.168.100.5, v6: the
  `dns.hosts` list, editable through its API) and an NPM proxy host to `http://192.168.100.10:10005`;
  neither lives in this repo. `*.local.internal` is not a wildcard: every name is its own record.
- **Homepage:** `scripts/add-glitchtip-to-homepage.sh` (dry-run by default) adds the GlitchTip row and
  its login to the `local.internal` page. The page lists credentials in plain text by design
  (LAN-only), so re-run it after rotating the admin password.

## Adding a service

Put it in `docker-compose.yml` at the `NEW SERVICES GO HERE` marker, right after GlitchTip. For a
service with persistent data: bind-mount `/data/stacks/monitoring/data/<name>`, add that dir with its
owner and mode to the `SPEC` list in `deploy.sh`, and add any new secrets to `.env`, `.env.example` and
`REQUIRED_ENV`. Ports stay in `10000-10099`. Then `./deploy.sh --dry-run` and `./deploy.sh`.

## Host services (outside Docker)

`deploy.sh` also applies `host/`: what the hypervisor and the VM run outside Docker. `host/<target>/files/`
mirrors `/` on that machine and `host/<target>/apply.sh` installs it; `deploy.sh` streams it over ssh and
runs it there, so nothing is left behind. Targets: `proxmox` (`PVE_SSH`, root@192.168.100.4) and
`docker-vm` (`DEPLOY_SSH`, run with sudo).

| Where | What | What deploy.sh manages |
|---|---|---|
| Proxmox | Samba share `backup_drive` (+ `wsdd2` for Windows discovery), anonymous FTP (ProFTPD, `ftp://192.168.100.4/`), NFS export to `192.168.100.8` and `.10`; all serve the NTFS backup drive at `/mnt/nfs/backup_drive` | packages, `smb.conf`, `proftpd.conf`, `/etc/exports`, the four `backup_drive.conf` start-order drop-ins, the drive's fstab line and its immutable bare mountpoint, service state |
| Proxmox | native File Browser on `:8080` (root `/tank`) | the pinned v2.63.23 binary (sha256-checked) and its unit file; the database and its `admin` user only when the database does not exist yet |
| Proxmox | `backup-pve-config` (03:00, tar of `/etc/pve` into `/tank/backup/pve-config`, 30 days) and `zfs-vm100-data-snapshot.sh` (03:30, snapshot of VM 100's data disk, keeps 7) | the scripts and their `/etc/cron.d` entries |
| Proxmox | Ceph monitor + manager (no OSDs, no pools) | **reported only**, never created or changed; `host/proxmox/reference/ceph.conf` is a record of its config |
| Swarm VM | `registry-retention.py` (04:00, keeps the 5 newest versions per repo in the local registry, then garbage-collects) | the script and its `/etc/cron.d` entry |

How `apply.sh` behaves, on both targets:

- **Idempotent.** A file that already matches byte for byte is not touched, so a deploy to the current hosts
  changes nothing. `./deploy.sh --dry-run` lists every file as `ok`, `DIFFERS` or `MISSING`.
- **Validated first.** A changed `smb.conf` goes through `testparm` and a changed `proftpd.conf` through
  `proftpd -t` before it replaces the live one. If either fails, nothing is replaced.
- **Backed up.** A replaced file is first copied to `/var/backups/monitoring_stack/<timestamp>/`, and only
  the services that depend on it are reloaded.
- **Fresh host.** It also installs the packages (`samba wsdd2 proftpd-core nfs-kernel-server`) and creates
  the File Browser database. That needs `PVE_FILEBROWSER_ADMIN_PASSWORD` in `.env` (see `.env.example`);
  an existing database is never touched, so the current host does not need it.
- **Ceph** is not created by `deploy.sh`: the current one has a monitor and a manager but no OSDs or pools,
  so it stores nothing. Set it up by hand on a new host if you want it.
- **Not captured:** the drive and its contents, the Samba password database (the `backupuser` account), the
  File Browser database, and the Docker daemon config on the VM (`/etc/docker/daemon.json`: `data-root` and
  the insecure registry; applying it restarts Docker, so it is not automated).

## What is and isn't in this repo

- **In git:** `docker-compose.yml`, `prometheus/`, `grafana-provisioning/`, `glitchtip/`, `deploy.sh`, `scripts/`, `host/`.
- **Not in git:** `.env` (secrets, see `.env.example`) and `data/` (about 1.5 GB of runtime
  state on the VM: Prometheus TSDB, Graylog, MongoDB, OpenSearch, Grafana and Portainer
  state). `deploy.sh` recreates the empty `data/<service>` dirs with the right owners, but
  **does not restore their contents**. On a fresh VM you get a working stack with no
  history: recreate the Graylog GELF UDP input (System -> Inputs, port 12201) and the users.
- **Outside this stack:** the openresty vhosts (e.g. `graylog.local.internal`) live in the
  VM's `proxy_stack`.

## Things to know

- `docker-compose.yml` bind-mounts absolute `/data/stacks/monitoring/...` paths, so the
  folder on the VM must stay exactly there.
- Six images are `:latest`. `deploy.sh` passes `--resolve-image changed` so a redeploy
  should not roll them; pin explicit versions in the compose file if you need
  reproducibility.
- Graylog's `ports:` also lists `12201:12201/udp` (added 2026-09-20). It was not deployed at
  copy time: until `./deploy.sh` runs, the VM only publishes `10002/udp`.
