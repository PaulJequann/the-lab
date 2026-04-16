
#!/usr/bin/env bash
set -euo pipefail
umask 077

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_root="{{ infisical_backup_mount_point }}/{{ infisical_postgres_db }}"
mkdir -p "$backup_root"

runuser -u postgres -- pg_dump \
  --format=custom \
  --file "$backup_root/{{ infisical_postgres_db }}-${timestamp}.dump" \
  "{{ infisical_postgres_db }}"

runuser -u postgres -- pg_dumpall --globals-only > "$backup_root/globals-${timestamp}.sql"

find "$backup_root" -type f -mtime +{{ infisical_backup_retention_days }} -delete
