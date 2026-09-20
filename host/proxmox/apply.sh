#!/usr/bin/env bash
# Proxmox hypervisor layer: what the host itself runs outside Docker.
#   * the backup-drive shares: Samba (+ wsdd2 discovery), anonymous FTP (ProFTPD), NFS server
#   * the native File Browser on :8080 (ISOs / backups / vmdata under /tank)
#   * the nightly /etc/pve config backup and the daily ZFS snapshot of VM 100's data disk
#   * Ceph: reported only, never created or changed (see README.md)
#
# Runs ON the Proxmox host, as root. deploy.sh streams this folder there over ssh; by hand:
#     bash apply.sh --dry-run     # report only, changes nothing
#     bash apply.sh               # apply
#
# Idempotent: a file that already matches is not touched. A changed config is validated before
# it replaces the live one (the old copy is kept under /var/backups/monitoring_stack/) and only
# the services that depend on it are reloaded. Never touched once they exist: the File Browser
# database, the Samba password database, the contents of the backup drive.
# shellcheck disable=SC2329  # install_filebrowser & co. are called through do_step "$@"
set -uo pipefail
DRY=0; [[ "${1:-}" == --dry-run ]] && DRY=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"

PACKAGES=(samba wsdd2 proftpd-core nfs-kernel-server)
SERVICES=(smbd nmbd wsdd2 proftpd nfs-server filebrowser)
UNITS=(etc/systemd/system/filebrowser.service
       etc/systemd/system/{nfs-server,smbd,nmbd,proftpd}.service.d/backup_drive.conf)

# File Browser: the release the host runs today. The sha256 is of the extracted binary and was
# checked to be identical to the one running on the host. Upstream archived the project on
# 2026-09-01, so this is a pin, not a "latest".
FB_VERSION=v2.63.23
FB_URL="https://github.com/filebrowser/filebrowser/releases/download/${FB_VERSION}/linux-amd64-filebrowser.tar.gz"
FB_SHA256=b6feb840abf2357022e1cf0df87f5ee88cb25ae9baec8e84d46e22af514b2746
FB_BIN=/usr/local/bin/filebrowser
FB_DB=/etc/filebrowser/filebrowser.db

# The NTFS backup drive that Samba, FTP and NFS all serve (design notes: storage-plan.md in the
# local-server repo). Mounted through fstab, no unit file.
DRIVE_MP=/mnt/nfs/backup_drive
DRIVE_UUID=49CF29420CFC5193
DRIVE_FSTAB="UUID=${DRIVE_UUID} ${DRIVE_MP} ntfs3 nofail,x-systemd.device-timeout=5s,x-systemd.mount-timeout=15s,noatime,uid=0,gid=0,umask=000 0 0"

install_filebrowser() {
  local t rc=0
  t="$(mktemp -d)" || return 1
  if curl -fsSL --max-time 180 -o "$t/fb.tar.gz" "$FB_URL" \
     && tar -xzf "$t/fb.tar.gz" -C "$t" filebrowser \
     && [[ "$(sha256sum "$t/filebrowser" | cut -d' ' -f1)" == "$FB_SHA256" ]] \
     && install -m 755 -o root -g root "$t/filebrowser" "$FB_BIN"; then :
  else
    echo "download, extract or checksum failed (pinned sha256 $FB_SHA256)" >&2; rc=1
  fi
  rm -rf "$t"
  return "$rc"
}

# Same settings the live database has (its `config cat` and `users ls` were compared with the live
# host's and are identical): root /tank, all interfaces, port 8080, one admin. `users add` also
# creates the scope directory, so on a host whose 'tank' pool is not mounted yet it leaves an empty
# /tank behind, which ZFS mounts over without complaint.
bootstrap_filebrowser() {
  install -d -m 700 -o root -g root "$(dirname "$FB_DB")" \
    && "$FB_BIN" config init -d "$FB_DB" \
    && "$FB_BIN" config set -d "$FB_DB" --address 0.0.0.0 --port 8080 --root /tank \
    && "$FB_BIN" users add admin "$FB_ADMIN_PASSWORD" --perm.admin --scope / -d "$FB_DB" \
    && chmod 600 "$FB_DB"
}

add_drive_fstab() {
  mkdir -p "$BACKUP_DIR/etc" && cp -a /etc/fstab "$BACKUP_DIR/etc/fstab" || return 1
  [[ -z "$(tail -c1 /etc/fstab)" ]] || echo >> /etc/fstab
  printf '%s\n' "$DRIVE_FSTAB" >> /etc/fstab && systemctl daemon-reload || return 1
  if blkid -U "$DRIVE_UUID" >/dev/null 2>&1 && ! mountpoint -q "$DRIVE_MP"; then mount "$DRIVE_MP"; fi
}

[[ "$(id -u)" -eq 0 ]] || { echo "    FAIL     must run as root"; exit 1; }
command -v pveversion >/dev/null || { echo "    FAIL     this is not a Proxmox host (pveversion not found)"; exit 1; }
say "host     $(pveversion | head -1)"

# ── preflight: everything that would stop a real run has to be known before it changes anything
if [[ ! -f "$FB_DB" ]]; then
  if [[ -z "${FB_ADMIN_PASSWORD:-}" ]]; then
    fail "$FB_DB does not exist yet, so its admin user has to be created: set PVE_FILEBROWSER_ADMIN_PASSWORD in .env"
  elif (( ${#FB_ADMIN_PASSWORD} < 12 )); then
    fail "PVE_FILEBROWSER_ADMIN_PASSWORD must be at least 12 characters (File Browser's minimum)"
  fi
fi
if (( BAD && ! DRY )); then exit 1; fi

# ── packages
echo "  packages"
missing=()
for p in "${PACKAGES[@]}"; do
  # shellcheck disable=SC2016  # ${Status} is dpkg-query's format string, not a shell variable
  if [[ "$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)" == "install ok installed" ]]; then
    say "ok       $p"
  else
    say "MISSING  package $p"; missing+=("$p")
  fi
done
if (( ${#missing[@]} )); then
  (( DRY )) || apt-get update -qq >/dev/null 2>&1 || say "NOTE     apt-get update reported errors (continuing)"
  do_step "apt-get install ${missing[*]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
fi

# ── backup drive: bare mountpoint, fstab entry
echo "  backup drive  ($DRIVE_MP)"
if [[ ! -d "$DRIVE_MP" ]]; then
  say "MISSING  $DRIVE_MP"
  do_step "mkdir -p $DRIVE_MP" mkdir -p "$DRIVE_MP"
fi
if mountpoint -q "$DRIVE_MP"; then
  say "ok       mounted (the immutable flag on the bare directory underneath cannot be checked while it is)"
elif lsattr -d "$DRIVE_MP" 2>/dev/null | cut -d' ' -f1 | grep -q i; then
  say "ok       not mounted, and the bare directory is immutable"
else
  do_step "chattr +i $DRIVE_MP  (nothing can write into the bare directory while the drive is absent)" chattr +i "$DRIVE_MP"
fi
if grep -qsE "^[^#]*[[:space:]]${DRIVE_MP}[[:space:]]" /etc/fstab; then
  say "ok       /etc/fstab has an entry for it"
else
  say "MISSING  /etc/fstab entry for $DRIVE_MP"
  do_step "append it (UUID=${DRIVE_UUID}, ntfs3, nofail), then mount the drive if it is attached" add_drive_fstab
fi
if ! mountpoint -q "$DRIVE_MP"; then
  if blkid -U "$DRIVE_UUID" >/dev/null 2>&1; then
    say "NOTE     the drive is attached but not mounted:  mount $DRIVE_MP && exportfs -ra"
  else
    say "NOTE     the drive (UUID $DRIVE_UUID) is not attached; the shares serve an empty, read-only directory until it is"
  fi
fi

# ── File Browser binary + database
echo "  File Browser  (native, $FB_VERSION)"
if [[ -x "$FB_BIN" ]]; then
  if [[ "$(sha256sum "$FB_BIN" | cut -d' ' -f1)" == "$FB_SHA256" ]]; then
    say "ok       $FB_BIN  (the pinned build)"
  else
    say "NOTE     $FB_BIN is not the pinned $FB_VERSION build ($("$FB_BIN" version 2>&1 | head -1)); left as is"
  fi
else
  say "MISSING  $FB_BIN"
  do_step "download $FB_VERSION and verify its sha256" install_filebrowser
fi
if [[ -f "$FB_DB" ]]; then
  say "ok       $FB_DB exists (never modified here)"
else
  say "MISSING  $FB_DB"
  do_step "create it: root /tank, 0.0.0.0:8080, admin user 'admin'" bootstrap_filebrowser
fi

# ── files
echo "  files"
plan_file etc/samba/smb.conf 644
plan_file etc/proftpd/proftpd.conf 644
plan_file etc/exports 644
for f in "${UNITS[@]}"; do plan_file "$f" 644; done
plan_file etc/cron.d/backup-pve-config 644
plan_file etc/cron.d/zfs-vm100-data-snapshot 644
plan_file usr/local/sbin/backup-pve-config 755
plan_file usr/local/sbin/zfs-vm100-data-snapshot.sh 755
if [[ -d /tank/backup ]]; then
  if [[ -d /tank/backup/pve-config ]]; then say "ok       /tank/backup/pve-config"
  else say "MISSING  /tank/backup/pve-config"; do_step "mkdir -p /tank/backup/pve-config" mkdir -p /tank/backup/pve-config; fi
else
  say "NOTE     /tank/backup does not exist: the nightly /etc/pve backup and the VM 100 snapshots need the 'tank' pool"
fi

# Validate the new configs BEFORE any of them replaces a live one.
if changed etc/samba/smb.conf; then
  if ! command -v testparm >/dev/null; then say "NOTE     testparm is not installed yet, so smb.conf was not validated"
  elif testparm -s --suppress-prompt "$HERE/files/etc/samba/smb.conf" >/dev/null 2>&1; then say "valid    smb.conf (testparm)"
  else fail "the new smb.conf does not pass testparm (run: testparm -s host/proxmox/files/etc/samba/smb.conf)"; fi
fi
if changed etc/proftpd/proftpd.conf; then
  if ! command -v proftpd >/dev/null; then say "NOTE     proftpd is not installed yet, so proftpd.conf was not validated"
  elif proftpd -t -c "$HERE/files/etc/proftpd/proftpd.conf" >/dev/null 2>&1; then say "valid    proftpd.conf (proftpd -t)"
  else fail "the new proftpd.conf does not pass proftpd -t (run: proftpd -t -c host/proxmox/files/etc/proftpd/proftpd.conf)"; fi
fi
if (( BAD && ! DRY )); then say "stopping before any config file is replaced"; exit 1; fi

apply_files
summary

# ── reload only what changed
echo "  reload"
any=0
if changed "${UNITS[@]}"; then do_step "systemctl daemon-reload" systemctl daemon-reload; any=1; fi
if changed etc/exports; then do_step "exportfs -ra" exportfs -ra; any=1; fi
if changed etc/samba/smb.conf; then do_step "reload smbd and nmbd" systemctl reload-or-restart smbd nmbd; any=1; fi
if changed etc/proftpd/proftpd.conf; then do_step "reload proftpd" systemctl reload-or-restart proftpd; any=1; fi
if changed etc/systemd/system/filebrowser.service; then do_step "restart filebrowser" systemctl restart filebrowser; any=1; fi
(( any )) || say "nothing to reload"

# ── services
echo "  services"
for u in "${SERVICES[@]}"; do ensure_service "$u"; done

# ── Ceph: reported, never managed (this host's Ceph has a monitor and a manager but no OSDs or pools)
echo "  Ceph  (reported only)"
if [[ -f /etc/pve/ceph.conf ]]; then
  node="$(hostname -s)"
  say "ok       configured: mon@$node $(systemctl is-active "ceph-mon@$node" 2>&1), mgr@$node $(systemctl is-active "ceph-mgr@$node" 2>&1); $(timeout 8 ceph osd stat 2>&1 | head -1)"
else
  say "NOTE     not initialised on this host and deploy.sh does not create it; reference: host/proxmox/reference/ceph.conf"
fi

finish
