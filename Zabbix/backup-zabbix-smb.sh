#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
DB_NAME="zabbix"
MOUNT="/mnt/backup-zabbix"
DEST="$MOUNT/Zabbix"
RETENTION_DAYS=7
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
LOG="/var/log/zabbix-db-backup.log"
FILE="$DEST/zabbix_${STAMP}.sql.gz"
TMP="$FILE.part"
exec >>"$LOG" 2>&1
trap 'rc=$?; rm -f -- "$TMP"; echo "$(date -Is) ERROR: backup failed (exit $rc)"; exit "$rc"' ERR
echo "$(date -Is) Starting backup"
if ! mountpoint -q "$MOUNT"; then
  echo "SMB share is not mounted at $MOUNT; refusing local backup" >&2
  exit 1
fi
if [[ ! -d "$DEST" || ! -w "$DEST" ]]; then
  echo "Backup destination unavailable or not writable: $DEST" >&2
  exit 1
fi
mariadb-admin ping --silent >/dev/null
mariadb-dump --single-transaction --quick --routines --events --triggers --hex-blob --databases "$DB_NAME" | gzip -c > "$TMP"
test -s "$TMP"
gzip -t "$TMP"
mv -n -- "$TMP" "$FILE"
find "$DEST" -maxdepth 1 -type f -name 'zabbix_*.sql.gz' -mtime +"$RETENTION_DAYS" -delete
echo "$(date -Is) Backup complete: $FILE ($(du -h "$FILE" | cut -f1))"
trap - ERR
