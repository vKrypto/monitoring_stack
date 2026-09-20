#!/bin/bash
# Daily protective snapshots for VM 100's data disk (excluded from vzdump
# via backup=0, see storage-plan.md Approach A). Keeps the last KEEP snapshots.
set -euo pipefail

DATASET="tank/vmdata/vm-100-disk-1"
PREFIX="auto"
KEEP=7

ts=$(date +%Y%m%d-%H%M%S)
zfs snapshot "${DATASET}@${PREFIX}-${ts}"
echo "[zfs-vm100-data-snapshot] created ${DATASET}@${PREFIX}-${ts}"

# prune old auto-snapshots beyond retention
mapfile -t snaps < <(zfs list -t snapshot -o name -s creation -H "${DATASET}" | grep "@${PREFIX}-")
count=${#snaps[@]}
if (( count > KEEP )); then
  to_delete=$(( count - KEEP ))
  for ((i=0; i<to_delete; i++)); do
    echo "[zfs-vm100-data-snapshot] pruning ${snaps[$i]}"
    zfs destroy "${snaps[$i]}"
  done
fi
