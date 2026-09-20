#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# ─────────────────────────────────────────────────────────────────────────────
# Add (or refresh) the GlitchTip row on the local.internal homepage: the static page
# served by the VM's proxy_stack (nginx:alpine, /data/stacks/proxy/data/homepage/index.html).
# The page lists real credentials in plain text by design (LAN-only, see its banner), in the
# same "email / password" style as the other services.
#
#   scripts/add-glitchtip-to-homepage.sh            dry-run (default): shows the row (password masked)
#   scripts/add-glitchtip-to-homepage.sh --apply    writes it, keeping a backup index.html.bak-<ts>
#
# Idempotent: re-running replaces the existing GlitchTip row, so run it again after rotating
# GLITCHTIP_ADMIN_PASSWORD. The row goes right after Graylog, followed by a marker comment
# where the next monitoring_stack service's row belongs. The page is served live from the
# bind mount, so --apply takes effect immediately: run it once GlitchTip is up.
# ─────────────────────────────────────────────────────────────────────────────

DEPLOY_SSH="${DEPLOY_SSH:-docker-vm}"
PAGE="/data/stacks/proxy/data/homepage/index.html"

usage() { echo "usage: $0 [--apply]   (default is a dry-run; details in the header of this file)"; }
APPLY=0
case "${1:-}" in
  "") ;;
  --apply) APPLY=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

[[ -f .env ]] || { echo "ERROR: .env missing in $(pwd)" >&2; exit 1; }
# shellcheck disable=SC1091
set -a; source .env; set +a
[[ -n "${GLITCHTIP_ADMIN_EMAIL:-}" && -n "${GLITCHTIP_ADMIN_PASSWORD:-}" ]] || { echo "ERROR: GLITCHTIP_ADMIN_EMAIL / GLITCHTIP_ADMIN_PASSWORD not set in .env" >&2; exit 1; }

echo "==> ${PAGE} on ${DEPLOY_SSH}$( ((APPLY)) || echo '   [DRY RUN - nothing will change]')"
# The password travels on stdin, never on a command line.
printf '{"email": "%s", "password": "%s", "apply": %s}' "$GLITCHTIP_ADMIN_EMAIL" "$GLITCHTIP_ADMIN_PASSWORD" "$APPLY" |
ssh -o BatchMode=yes -o ConnectTimeout=8 "$DEPLOY_SSH" "python3 -c '
import html, json, shutil, sys, time
cfg = json.load(sys.stdin)
path = \"${PAGE}\"
marker = \"<!-- monitoring_stack: add new services below this line -->\"
s = open(path, encoding=\"utf-8\").read()
row = (\"        <li><a href=\\\"http://glitchtip.local.internal\\\">GlitchTip</a>\"
       \"<span class=\\\"desc\\\">error tracking, all projects \u00b7 :10005</span>\"
       \"<span class=\\\"creds\\\">%s / %s</span></li>\") % (html.escape(cfg[\"email\"]), html.escape(cfg[\"password\"]))
lines = s.split(\"\\n\")
had = any(\"glitchtip.local.internal\" in l for l in lines)
out = [l for l in lines if \"glitchtip.local.internal\" not in l and marker not in l]
idx = next((i for i, l in enumerate(out) if \"graylog.local.internal\" in l), None)
if idx is None:
    sys.exit(\"could not find the Graylog row to anchor after - page layout changed, edit by hand\")
out[idx + 1:idx + 1] = [row, \"        \" + marker]
new = \"\\n\".join(out)
masked = row.replace(html.escape(cfg[\"password\"]), \"<password from .env>\")
print(\"    existing GlitchTip row: \" + (\"yes -> will be replaced\" if had else \"no -> will be inserted after Graylog\"))
print(\"    row: \" + masked.strip())
if new == s:
    print(\"    => already up to date, no change\")
elif not cfg[\"apply\"]:
    print(\"    => dry-run: page would change (%d -> %d lines)\" % (len(lines), len(new.split(\"\\n\"))))
else:
    backup = path + \".bak-\" + time.strftime(\"%Y%m%d-%H%M%S\")
    shutil.copy2(path, backup)
    open(path, \"w\", encoding=\"utf-8\").write(new)
    print(\"    => written. backup: \" + backup)
'"
