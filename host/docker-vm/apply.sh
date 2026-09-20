#!/usr/bin/env bash
# Swarm VM layer: the host-level job that lives next to the Docker stacks.
#   * registry-retention: daily 04:00, keeps the 5 newest unique versions per repository in the
#     local registry (registry_stack) and garbage-collects the blobs that frees.
#
# Runs ON the VM, as root (deploy.sh calls it with sudo). By hand:
#     sudo bash apply.sh --dry-run     # report only, changes nothing
#     sudo bash apply.sh               # apply
# Same rules as host/proxmox/apply.sh: idempotent, byte-compared, old copies backed up.
set -uo pipefail
DRY=0; [[ "${1:-}" == --dry-run ]] && DRY=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"

[[ "$(id -u)" -eq 0 ]] || { echo "    FAIL     must run as root"; exit 1; }
say "host     $(uname -n)"

echo "  prerequisites"
for c in python3 docker; do   # the script talks to the registry over HTTP and runs `docker exec` for the GC
  if command -v "$c" >/dev/null; then say "ok       $c"; else fail "$c is not installed (registry-retention.py needs it)"; fi
done
if (( BAD && ! DRY )); then exit 1; fi

echo "  files"
plan_file usr/local/sbin/registry-retention.py 755
plan_file etc/cron.d/registry-retention 644
apply_files
summary

finish
