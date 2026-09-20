#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# ─────────────────────────────────────────────────────────────────────────────
# Recreate the monitoring stack (Graylog + OpenSearch + MongoDB, Grafana,
# Prometheus, node-exporter, cAdvisor, Portainer, Filebrowser) on the Proxmox
# Swarm VM from THIS folder.
#
#   ./deploy.sh --dry-run    read-only: run every check, show what would be
#                            created/copied, change nothing, deploy nothing
#   ./deploy.sh              create data dirs, copy config, `docker stack deploy`
#
# Layout on the VM (REMOTE_STACK_DIR is fixed: docker-compose.yml bind-mounts
# these absolute paths):
#   /data/stacks/monitoring/
#     docker-compose.yml  .env  prometheus/  grafana-provisioning/  glitchtip/   <- from this repo
#     data/<service>/                                                <- runtime state, never in git
#
# Not covered here: the openresty vhosts (e.g. graylog.local.internal) live in
# the VM's proxy_stack, and the service data itself (see README.md).
# ─────────────────────────────────────────────────────────────────────────────

DEPLOY_SSH="${DEPLOY_SSH:-docker-vm}"                 # ssh alias -> ubuntu@192.168.100.10
STACK_NAME="${STACK_NAME:-monitoring_stack}"
COMPOSE_FILE="docker-compose.yml"
REMOTE_STACK_DIR="/data/stacks/monitoring"
REQUIRED_ENV=(GRAFANA_ADMIN_PASSWORD GRAYLOG_PASSWORD_SECRET GRAYLOG_ROOT_PASSWORD_SHA2
              OPENSEARCH_INITIAL_ADMIN_PASSWORD FILEBROWSER_ADMIN_PASSWORD_HASH
              GLITCHTIP_DB_PASSWORD GLITCHTIP_SECRET_KEY GLITCHTIP_ADMIN_EMAIL GLITCHTIP_ADMIN_PASSWORD)
SYNC_ITEMS=("$COMPOSE_FILE" .env prometheus grafana-provisioning glitchtip)

usage() { echo "usage: $0 [--dry-run]   (--dry-run changes nothing; details in the header of this file)"; }

DRY_RUN=0
case "${1:-}" in
  "") ;;
  -n|--dry-run) DRY_RUN=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

die() { echo "ERROR: $*" >&2; exit 1; }

banner="==> Target: ${DEPLOY_SSH}  (stack ${STACK_NAME} @ ${REMOTE_STACK_DIR})"
if (( DRY_RUN )); then banner+="  [DRY RUN - nothing will change]"; fi
echo "$banner"

# ── 1. Local checks ─────────────────────────────────────────────────────────
echo "==> Local checks"
[[ -f .env ]] || die ".env missing - copy .env.example to .env and fill it in"
# shellcheck disable=SC1091
set -a; source .env; set +a
missing=()
for v in "${REQUIRED_ENV[@]}"; do [[ -n "${!v:-}" ]] || missing+=("$v"); done
(( ${#missing[@]} == 0 )) || die ".env is missing or empty: ${missing[*]}"
render_err="$(docker stack config -c "$COMPOSE_FILE" 2>&1 >/dev/null)" || die "${COMPOSE_FILE} does not render: ${render_err}"
[[ "$render_err" != *"is not set"* ]] || die "${COMPOSE_FILE} uses an unset variable: ${render_err}"
ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEPLOY_SSH" true || die "cannot ssh to ${DEPLOY_SSH}"
echo "    .env complete, compose renders, ssh ok"

# ── 2. VM prerequisites + data directories ─────────────────────────────────
# Swarm (unlike `docker run`) does not auto-create missing bind-mount paths, and
# each service runs as its own UID, so every data dir is created with the owner
# and mode the live VM has today. `install -d` touches only the directory itself
# (never its contents), so existing data is safe. In --dry-run nothing is changed.
echo "==> VM prerequisites and data directories"
prep_rc=0
ssh "$DEPLOY_SSH" "bash -s -- '${DRY_RUN}' '${REMOTE_STACK_DIR}'" <<'REMOTE' || prep_rc=$?
set -uo pipefail
dry="$1"; top="$2"; bad=0

[[ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)" == true ]] \
  || { echo "    FAIL  this host is not a Swarm manager"; bad=1; }
mm="$(sysctl -n vm.max_map_count)"
(( mm >= 262144 )) || { echo "    FAIL  vm.max_map_count=${mm} (< 262144): OpenSearch will not start."
  echo "          fix: sudo sysctl -w vm.max_map_count=262144 && echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf"; bad=1; }
[[ -d /data/docker ]] || { echo "    FAIL  /data/docker missing (cAdvisor bind-mounts it as the docker root)"; bad=1; }

# relative-path uid gid mode   (mirrors the live VM)
SPEC=(
  ". 1000 1000 0775"
  "data 1000 1000 0755"
  "data/filebrowser 1000 1000 0775"
  "data/glitchtip-db 1000 1000 0700"
  "data/grafana 472 0 0777"
  "data/graylog 1100 1100 0750"
  "data/mongodb 999 999 0755"
  "data/opensearch 1000 1000 0755"
  "data/portainer 1000 1000 0755"
  "data/prometheus 65534 65534 0775"
)
if [[ ! -d "$(dirname "$top")" ]]; then
  if (( dry )); then echo "    MISSING $(dirname "$top") (would create)"; else sudo -n mkdir -p "$(dirname "$top")"; fi
fi
for row in "${SPEC[@]}"; do
  read -r rel uid gid mode <<<"$row"
  dir="$top/$rel"; [[ "$rel" == . ]] && dir="$top"
  want="${uid}:${gid} $(printf '%04o' "$((8#$mode))")"
  if [[ -d "$dir" ]]; then
    have="$(stat -c '%u:%g' "$dir") $(printf '%04o' "$((8#$(stat -c '%a' "$dir")))")"
    if [[ "$have" == "$want" ]]; then echo "    ok       ${rel}  (${have})"
    elif (( dry )); then echo "    DIFFERS  ${rel}  is ${have}, spec ${want}"
    else sudo -n install -d -o "$uid" -g "$gid" -m "$mode" "$dir"; echo "    fixed    ${rel}  (${have} -> ${want})"; fi
  elif (( dry )); then echo "    MISSING  ${rel}  (would create as ${want})"
  else sudo -n install -d -o "$uid" -g "$gid" -m "$mode" "$dir"; echo "    created  ${rel}  (${want})"; fi
done
exit "$bad"
REMOTE
if (( prep_rc != 0 )); then
  (( DRY_RUN )) || die "VM prerequisites failed (see FAIL lines above); nothing was deployed"
  echo "    (dry-run: prerequisites above would block a real deploy)"
fi

# ── 3. Ship the config ─────────────────────────────────────────────────────
# Only the tracked config goes over; data/ is never touched. rsync -a keeps
# .env at mode 600.
if (( DRY_RUN )); then
  echo "==> [dry-run] config that would be copied (rsync -n)"
  if ssh "$DEPLOY_SSH" "test -d '${REMOTE_STACK_DIR}'"; then
    changes="$(rsync -azn --itemize-changes "${SYNC_ITEMS[@]}" "${DEPLOY_SSH}:${REMOTE_STACK_DIR}/" | grep -v '^\.d' || true)"
    echo "${changes:-    (no changes: the VM already has exactly this config)}"
  else
    echo "    (${REMOTE_STACK_DIR} does not exist yet: everything would be copied)"
  fi
  echo "==> [dry-run] would run on the VM:"
  echo "    docker stack deploy --detach=true --resolve-image changed -c ${COMPOSE_FILE} ${STACK_NAME}"
  (( prep_rc == 0 )) || exit 1
  exit 0
fi

echo "==> Copying config -> ${DEPLOY_SSH}:${REMOTE_STACK_DIR}/"
rsync -az "${SYNC_ITEMS[@]}" "${DEPLOY_SSH}:${REMOTE_STACK_DIR}/"

# ── 4. Deploy the stack ON the VM ─────────────────────────────────────────
# Run it there so ${VAR} interpolation resolves against the copied .env.
# --resolve-image changed: only look up image digests for services that are new
# or whose image reference changed, so a redeploy does not silently roll the
# `:latest` images (grafana, prometheus, portainer, ...) to whatever is newest.
# No --prune: services outside this file are never removed.
echo "==> Deploying stack ${STACK_NAME} on ${DEPLOY_SSH}"
ssh "$DEPLOY_SSH" "cd '${REMOTE_STACK_DIR}' \
  && set -a && . ./.env && set +a \
  && docker stack deploy --detach=true --resolve-image changed -c '${COMPOSE_FILE}' '${STACK_NAME}'"

# ── 5. Wait for convergence + report ─────────────────────────────────────
# Graylog/OpenSearch are JVMs and can take a minute or two to report healthy.
# glitchtip_migrate is a run-once job that settles at 0/1 - that counts as done.
echo "==> Waiting for services to converge..."
ssh "$DEPLOY_SSH" "bash -s '${STACK_NAME}'" <<'REMOTE'
set -euo pipefail
stack="$1"
migrate_state() { docker service ps "${stack}_glitchtip_migrate" --format '{{.CurrentState}}' 2>/dev/null | head -1 || true; }
for _ in $(seq 1 60); do
  pending=$(docker stack services "$stack" --format '{{.Name}} {{.Replicas}}' | awk '{
    split($2,a,"/"); n=$1; sub(/^'"$stack"'_/,"",n);
    if (n=="glitchtip_migrate") next;
    if (a[1]!=a[2]) printf "%s(%s) ", n, $2
  }')
  mig="$(migrate_state)"
  case "$mig" in Complete*|"") mig_done=1 ;; *) mig_done=0 ;; esac
  [ -z "$pending" ] && [ "$mig_done" = 1 ] && break
  echo "    $(date +%T) waiting: ${pending}$([ "$mig_done" = 1 ] || echo "glitchtip_migrate(${mig})")"
  sleep 10
done
docker stack services "$stack"
# A run-once job settles at 0/1 whether it succeeded or failed, so check its outcome explicitly.
mig="$(migrate_state)"
case "$mig" in
  Complete*|"") ;;
  *) echo "ERROR: glitchtip_migrate did not complete: ${mig} (docker service logs ${stack}_glitchtip_migrate)" >&2; exit 3 ;;
esac
REMOTE
echo
echo "==> Done."
echo "    Grafana     http://192.168.100.10:10000"
echo "    Graylog     http://192.168.100.10:10001   (GELF UDP: 10002 and 12201)"
echo "    Portainer   https://192.168.100.10:10003"
echo "    Filebrowser http://192.168.100.10:10004"
echo "    GlitchTip   http://192.168.100.10:10005   (login: ${GLITCHTIP_ADMIN_EMAIL}, password in .env)"
