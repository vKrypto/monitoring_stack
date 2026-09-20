#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# ─────────────────────────────────────────────────────────────────────────────
# ONE-TIME: move GlitchTip from job_seeker_stack to monitoring_stack and keep its
# Postgres data.
#
#   scripts/migrate-glitchtip-from-job-seeker.sh            dry-run (default): checks + plan, changes nothing
#   scripts/migrate-glitchtip-from-job-seeker.sh --apply    do it
#
# --apply, in order (GlitchTip is down from step 3 until step 5 finishes: a few minutes):
#   1. checks: ssh, source data dir, destination free; works out where a previous run stopped
#   2. pg_dump backup of the live DB -> /data/stacks/monitoring/backups/glitchtip-<ts>.sql.gz
#   3. remove GlitchTip + its postgres exporter from job_seeker_stack (consumers first, DB last)
#   4. cp -a the Postgres data dir here (keeps 1000:1000 / 0700); the original is renamed
#      <dir>.moved-<ts>, never deleted
#   5. ./deploy.sh  -> the services start here on the copied data; the admin bootstrap runs
#   6. verify: web answers, the admin can log in, open signup is refused
# Re-running after a failure resumes: if the old services are already gone and the new data
# dir is in place, steps 2-4 are skipped.
#
# Merge the job-seeker change that removes GlitchTip from its stack files BEFORE the next
# job-seeker deploy, otherwise that deploy recreates the old services (with an empty DB).
#
# Rollback (while the .moved-* dir still exists):
#   ssh docker-vm 'docker service rm monitoring_stack_glitchtip{,_worker,_migrate,_db,_redis,_postgres_exporter}'
#   ssh docker-vm 'cd /data/stacks/monitoring/data && sudo mv glitchtip-db glitchtip-db.discard'
#   ssh docker-vm 'sudo mv /data/job-seeker/stack_fs/data/glitchtip-db.moved-<ts> /data/job-seeker/stack_fs/data/glitchtip-db'
#   ...then redeploy job-seeker from a commit that still defines the GlitchTip services.
# ─────────────────────────────────────────────────────────────────────────────

DEPLOY_SSH="${DEPLOY_SSH:-docker-vm}"
OLD_STACK="${OLD_STACK:-job_seeker_stack}"
OLD_DATA="${OLD_DATA:-/data/job-seeker/stack_fs/data/glitchtip-db}"
NEW_DATA="/data/stacks/monitoring/data/glitchtip-db"
BACKUP_DIR="/data/stacks/monitoring/backups"
OLD_SERVICES=(glitchtip glitchtip_worker glitchtip_migrate postgres_exporter glitchtip_db)  # consumers first, DB last
WEB_URL="http://192.168.100.10:10005"
TS="$(date +%Y%m%d-%H%M%S)"

usage() { echo "usage: $0 [--apply]   (default is a dry-run; details in the header of this file)"; }
APPLY=0
case "${1:-}" in
  "") ;;
  --apply) APPLY=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
die() { echo "ERROR: $*" >&2; exit 1; }
vm() { ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEPLOY_SSH" "$@"; }
act() {  # run on the VM only with --apply, otherwise just show it
  if (( APPLY )); then echo "    + $*"; vm "$*"; else echo "    [dry-run] would run on ${DEPLOY_SSH}: $*"; fi
}

echo "==> GlitchTip move: ${OLD_STACK} -> monitoring_stack$( ((APPLY)) || echo '   [DRY RUN - nothing will change]')"

# ── 1. Checks ──────────────────────────────────────────────────────────────
[[ -f .env ]] || die ".env missing in $(pwd)"
# shellcheck disable=SC1091
set -a; source .env; set +a
[[ -n "${GLITCHTIP_ADMIN_EMAIL:-}" && -n "${GLITCHTIP_ADMIN_PASSWORD:-}" ]] || die "GLITCHTIP_ADMIN_EMAIL / GLITCHTIP_ADMIN_PASSWORD not set in .env"
vm true || die "cannot ssh to ${DEPLOY_SSH}"

old_services_present="$(vm "docker service ls --format '{{.Name}}' | grep -c '^${OLD_STACK}_glitchtip' || true")"
new_data_ready="$(vm "sudo -n test -f '${NEW_DATA}/PG_VERSION' && echo yes || echo no")"
old_data_ready="$(vm "sudo -n test -f '${OLD_DATA}/PG_VERSION' && echo yes || echo no")"
echo "    old GlitchTip services in ${OLD_STACK}: ${old_services_present}   old data dir: ${old_data_ready}   new data dir: ${new_data_ready}"

if [[ "$new_data_ready" == yes && "$old_services_present" != 0 ]]; then
  die "both the new data dir and the old services exist - ambiguous, resolve by hand (see rollback in the header)"
fi
if [[ "$new_data_ready" == no && "$old_data_ready" == no ]]; then
  die "no Postgres data found in ${OLD_DATA} or ${NEW_DATA} (a fresh install needs no migration: just run ./deploy.sh)"
fi
RESUME=0; [[ "$new_data_ready" == yes && "$old_services_present" == 0 ]] && RESUME=1
(( RESUME )) && echo "    -> resuming: data is already in place, skipping steps 2-4"

if (( ! RESUME )); then
  # ── 2. Backup ────────────────────────────────────────────────────────────
  echo "==> 2. Backup (pg_dump) -> ${BACKUP_DIR}/glitchtip-${TS}.sql.gz"
  # pipefail + gzip -t + a size floor: a failed pg_dump must stop the migration BEFORE step 3 removes anything.
  act "set -o pipefail; mkdir -p '${BACKUP_DIR}' && docker exec \$(docker ps -q -f 'name=^${OLD_STACK}_glitchtip_db\\.' | head -1) pg_dump -U glitchtip glitchtip | gzip > '${BACKUP_DIR}/glitchtip-${TS}.sql.gz' && gzip -t '${BACKUP_DIR}/glitchtip-${TS}.sql.gz' && [ \"\$(stat -c %s '${BACKUP_DIR}/glitchtip-${TS}.sql.gz')\" -gt 5000 ] && ls -l '${BACKUP_DIR}/glitchtip-${TS}.sql.gz'"

  # ── 3. Stop the old services ────────────────────────────────────────────
  echo "==> 3. Remove GlitchTip from ${OLD_STACK} (GlitchTip is down until step 5 finishes)"
  for s in "${OLD_SERVICES[@]}"; do act "docker service rm '${OLD_STACK}_${s}' 2>/dev/null || true"; done
  act "for i in \$(seq 1 30); do [ -z \"\$(docker ps -q -f 'name=^${OLD_STACK}_glitchtip_db\\.')\" ] && break; sleep 2; done; [ -z \"\$(docker ps -q -f 'name=^${OLD_STACK}_glitchtip_db\\.')\" ] && echo 'old Postgres container stopped'"

  # ── 4. Copy the data ────────────────────────────────────────────────────
  echo "==> 4. Copy the Postgres data dir (original kept as ${OLD_DATA}.moved-${TS})"
  act "sudo -n test ! -e '${NEW_DATA}' && sudo -n cp -a '${OLD_DATA}' '${NEW_DATA}' && sudo -n mv '${OLD_DATA}' '${OLD_DATA}.moved-${TS}' && stat -c '%u:%g %a %n' '${NEW_DATA}'"
fi

# ── 5. Deploy the monitoring stack ──────────────────────────────────────────
echo "==> 5. ./deploy.sh$( ((APPLY)) || echo ' --dry-run')"
if (( APPLY )); then ./deploy.sh; else ./deploy.sh --dry-run | sed 's/^/    /'; fi

# ── 6. Verify ───────────────────────────────────────────────────────────────
echo "==> 6. Verify"
if (( ! APPLY )); then
  echo "    [dry-run] would wait for ${WEB_URL}/api/settings/, log in as ${GLITCHTIP_ADMIN_EMAIL}, and confirm open signup is refused"
  exit 0
fi
for _ in $(seq 1 60); do [[ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "${WEB_URL}/api/settings/")" == 200 ]] && break; sleep 5; done
[[ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "${WEB_URL}/api/settings/")" == 200 ]] || die "GlitchTip did not come up at ${WEB_URL}"
jar="$(mktemp)"; trap 'rm -f "$jar"' EXIT
curl -s -c "$jar" -b "$jar" -m 10 -o /dev/null "${WEB_URL}/_allauth/browser/v1/config"
tok="$(awk '$6=="csrftoken"{print $7}' "$jar")"
login="$(printf '{"email":"%s","password":"%s"}' "$GLITCHTIP_ADMIN_EMAIL" "$GLITCHTIP_ADMIN_PASSWORD" |
  curl -s -c "$jar" -b "$jar" -m 10 -H "X-CSRFToken: $tok" -H "Origin: ${WEB_URL}" -H 'Content-Type: application/json' --data-binary @- "${WEB_URL}/_allauth/browser/v1/auth/login")"
grep -q '"is_authenticated": *true' <<<"$login" || die "admin login FAILED at ${WEB_URL} (check: docker service logs monitoring_stack_glitchtip_migrate)"
echo "    PASS  admin ${GLITCHTIP_ADMIN_EMAIL} can log in"
anon="$(mktemp)"; curl -s -c "$anon" -b "$anon" -m 10 -o /dev/null "${WEB_URL}/_allauth/browser/v1/config"
atok="$(awk '$6=="csrftoken"{print $7}' "$anon")"
code="$(curl -s -c "$anon" -b "$anon" -m 10 -o /dev/null -w '%{http_code}' -H "X-CSRFToken: $atok" -H "Origin: ${WEB_URL}" -H 'Content-Type: application/json' \
  -d '{"email":"probe@example.com","password":"Probe-Pass-12345xyz"}' "${WEB_URL}/_allauth/browser/v1/auth/signup")"; rm -f "$anon"
[[ "$code" == 403 ]] && echo "    PASS  open signup refused (HTTP 403)" || echo "    WARN  signup probe returned HTTP ${code} (expected 403)"
echo "==> Done. GlitchTip: ${WEB_URL}  (data now in ${NEW_DATA}; the old copy is ${OLD_DATA}.moved-${TS} - delete it once you are happy)"
