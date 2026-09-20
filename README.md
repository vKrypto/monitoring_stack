# monitoring_stack

Source of truth for the Swarm stack `monitoring_stack` on the Proxmox VM
(`192.168.100.10`). Copied from `/data/stacks/monitoring` on 2026-09-20.

| Service | Port on the VM | Notes |
|---|---|---|
| Grafana | 10000 | dashboards provisioned from `grafana-provisioning/` |
| Graylog | 10001 (UI), 10002/udp and 12201/udp (GELF) | UI is also fronted at `http://graylog.local.internal/` by the VM's `proxy_stack` |
| Portainer | 10003 (https) | |
| Filebrowser | 10004 | read-only view of `/data/stacks` |
| Prometheus, node-exporter, cAdvisor, OpenSearch, MongoDB | internal only | overlay network `monitoring_stack_monitoring` |

## Deploy

```bash
cp .env.example .env      # first time only, then fill it in
./deploy.sh --dry-run     # read-only: checks + what would change
./deploy.sh               # create data dirs, copy config, docker stack deploy
```

`deploy.sh` needs the ssh alias `docker-vm` (ubuntu, passwordless sudo) and a
Swarm manager with `vm.max_map_count >= 262144` (OpenSearch) and `/data/docker`
present (cAdvisor). It checks all of this and prints the fix if something is off.

## What is and isn't in this repo

- **In git:** `docker-compose.yml`, `prometheus/`, `grafana-provisioning/`, `deploy.sh`.
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
