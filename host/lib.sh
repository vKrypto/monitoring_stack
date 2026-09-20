#!/usr/bin/env bash
# Shared helpers for host/<target>/apply.sh -- sourced, never run directly.
#
# An apply.sh runs ON the target host, as root. deploy.sh streams it there together with its
# files/ tree (which mirrors / on that host) and removes the copy afterwards; it can also be
# run by hand from a checkout. The caller sets DRY (0|1) and HERE (its own directory) before
# sourcing this file.
#
# One rule for every helper: a dry run only reports; a real run validates first, keeps a copy
# of anything it replaces, and touches only what actually differs.

BACKUP_DIR="/var/backups/monitoring_stack/$(date +%Y%m%dT%H%M%S)"
BAD=0                        # set by fail(); the apply.sh exits non-zero through finish()
ORDER=()                     # planned files, in the order the apply.sh lists them
declare -A STATE=() MODE=()  # path relative to / -> ok|missing|differs|perms, and its mode

say()  { printf '    %s\n' "$*"; }
fail() { say "FAIL     $*"; BAD=1; }

# plan_file <path relative to /> <mode>
# Compares files/<path> with the live file. Changes nothing; apply_files() does the work.
plan_file() {
  local rel="$1" mode="$2" src="$HERE/files/$1" dst="/$1" have=""
  ORDER+=("$rel"); MODE[$rel]="$mode"; STATE[$rel]=ok
  [[ -f "$src" ]] || { fail "/$rel is listed but is missing from the staged files"; return; }
  [[ -e "$dst" ]] && have="$(stat -c '%a %U:%G' "$dst")"
  if [[ -z "$have" ]]; then
    STATE[$rel]=missing; say "MISSING  /$rel  (mode $mode)"
  elif ! cmp -s "$src" "$dst"; then
    STATE[$rel]=differs; say "DIFFERS  /$rel  (the repo copy replaces it; the old one is backed up)"
  elif [[ "$have" != "$mode root:root" ]]; then
    STATE[$rel]=perms; say "PERMS    /$rel  is $have, want $mode root:root"
  else
    say "ok       /$rel"
  fi
}

# changed <path relative to />...   true if any of them is (or would be) created or replaced
changed() {
  local rel
  for rel in "$@"; do
    [[ "${STATE[$rel]:-ok}" == missing || "${STATE[$rel]:-ok}" == differs ]] && return 0
  done
  return 1
}

# apply_files   real runs only: install every planned file that is not ok. A replaced file is
# copied to $BACKUP_DIR first, and the new one is written next to it and renamed into place.
apply_files() {
  local rel src dst tmp
  (( DRY )) && return 0
  for rel in "${ORDER[@]}"; do
    src="$HERE/files/$rel"; dst="/$rel"
    case "${STATE[$rel]}" in
      ok) continue ;;
      perms)
        if chmod "${MODE[$rel]}" "$dst" && chown root:root "$dst"; then say "fixed    /$rel  (permissions)"
        else fail "could not fix the permissions of /$rel"; fi
        continue ;;
      differs)
        if ! { mkdir -p "$(dirname "$BACKUP_DIR/$rel")" && cp -a "$dst" "$BACKUP_DIR/$rel"; }; then
          fail "could not back up /$rel, so it was left untouched"; continue
        fi ;;
    esac
    tmp="$dst.new.$$"
    if install -D -m "${MODE[$rel]}" -o root -g root "$src" "$tmp" && mv -f "$tmp" "$dst"; then
      say "installed /$rel"
    else
      rm -f "$tmp"; fail "could not install /$rel"
    fi
  done
}

# do_step <description> <command...>   real run: run it (its output is shown only if it fails);
# dry run: only say what it would do.
do_step() {
  local desc="$1" out
  shift
  if (( DRY )); then say "would    $desc"; return 0; fi
  if out="$("$@" 2>&1)"; then
    say "done     $desc"
  else
    fail "$desc"
    [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/              /'
  fi
}

# ensure_service <unit>   enabled and running; a real run enables and starts it if it is not.
ensure_service() {
  local u="$1" en act
  en="$(systemctl is-enabled "$u" 2>/dev/null)"; act="$(systemctl is-active "$u" 2>/dev/null)"
  if [[ "$en" == enabled && "$act" == active ]]; then
    say "ok       $u  (enabled, active)"
  elif (( DRY )); then
    say "DOWN     $u  is ${en:-unknown}/${act:-unknown}  (would enable --now)"
  elif systemctl enable --now "$u" >/dev/null 2>&1; then
    say "started  $u"
  else
    fail "$u could not be enabled/started (journalctl -u $u)"
  fi
}

summary() {
  local rel n=0
  for rel in "${ORDER[@]}"; do [[ "${STATE[$rel]}" != ok ]] && n=$((n + 1)); done
  say "files    $n of ${#ORDER[@]} $( (( DRY )) && echo 'would change' || echo 'changed' )"
}

finish() { (( BAD )) && exit 1; exit 0; }
