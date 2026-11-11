#!/bin/bash
# Run on the active host. Publish only complete archive/secret/checksum sets.
set -euo pipefail
umask 077
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$(hostname -s)" in
  alo|almalinxo) local_mount=/mnt/O3T; destination=/mnt/O3T/code/gitlabc/.backups/continuity; peer=192.168.86.141; peer_mount=/mnt/spare; remote=/mnt/spare/code/gitlabc/.backups/continuity ;;
  almalt) local_mount=/mnt/spare; destination=/mnt/spare/code/gitlabc/.backups/continuity; peer=192.168.86.80; peer_mount=/mnt/O3T; remote=/mnt/O3T/code/gitlabc/.backups/continuity ;;
  *) echo 'Unknown host; refusing backup.' >&2; exit 1 ;;
esac
# An absent mount must never silently write into the underlying filesystem.
mountpoint -q "$local_mount" || { echo "Missing mount: $local_mount" >&2; exit 1; }
ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq 192.168.86.50 || { echo 'Standby host: no backup attempted.'; exit 0; }
mkdir -p "$destination"
exec 9>"$destination/.backup.lock"
flock -n 9 || { echo 'Backup already running.' >&2; exit 1; }
stage=$(mktemp -d "$destination/.partial.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
# The user accepted the NTFS mount permissions and plaintext local copies.
BACKUP_KEEP_COUNT=100000 BACKUP_DIR="$stage" bash "$root/scripts/backup_gitlab.sh"
shopt -s nullglob
archives=("$stage"/*_gitlab_backup.tar)
(( ${#archives[@]} == 1 )) || { echo 'Expected exactly one archive.' >&2; exit 1; }
[[ -s "$stage/gitlab-rails-secrets.yaml" ]] || { echo 'Missing Rails secrets.' >&2; exit 1; }
name="$(basename "${archives[0]}" .tar)"
(cd "$stage"; sha256sum "$(basename "${archives[0]}")" gitlab-rails-secrets.yaml > SHA256SUMS; sha256sum -c SHA256SUMS)
[[ ! -e "$destination/$name" ]] || { echo 'Backup set already exists.' >&2; exit 1; }
mv "$stage" "$destination/$name"
stage=''
trap - EXIT
# Retry every locally published set whose peer copy has not been verified.
# Never mirror or delete remote backups.
failed=0
for setdir in "$destination"/*_gitlab_backup; do
  [[ -d "$setdir" && ! -e "$setdir/.replicated" ]] || continue
  name="${setdir##*/}"
  echo "Replicating $name to $peer"
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "$peer" "mountpoint -q '$peer_mount' && mkdir -p '$remote/.$name.partial'" &&
     rsync -a --partial --exclude=.replicated -- "$setdir/" "$peer:$remote/.$name.partial/" &&
     ssh -o BatchMode=yes -o ConnectTimeout=10 "$peer" "cd '$remote/.$name.partial' && sha256sum -c SHA256SUMS && cd .. && if test -e '$name'; then cmp '.$name.partial/SHA256SUMS' '$name/SHA256SUMS' && (cd '$name' && sha256sum -c SHA256SUMS) && rm -rf '.$name.partial'; else mv '.$name.partial' '$name'; fi"; then
    touch "$setdir/.replicated"
  else
    echo "ERROR: Peer replication failed for $name; will retry at the next run." >&2
    failed=1
  fi
done
(( failed == 0 )) || exit 1
echo "Verified backup set on both hosts: $name"
