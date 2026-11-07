#!/usr/bin/env bash
# Final backup of bohr's native (Ubuntu 20.04, bare-metal) production apps to
# this machine, before bohr is reinstalled with Debian 13:
#   - vfll.de                        vfllcms       (DB vfllcms)
#   - veranstaltungskalender.vfll.de eventmanager  (DB vfllfobi_dev, ~/eventmanager_dev)
#
# Run from the control machine (no sudo on bohr needed):
#   playbooks/bohr_migration/backup_bohr_native.sh [target_dir]
#
# Write freeze first, on bohr (otherwise writes after the dump are lost):
#   sudo supervisorctl stop vfllcms eventmanager_dev
#   crontab -e   # comment out backup_*.sh, get_events.sh, get_blog.sh, django-cronjobs
# The script refuses to run while gunicorn is still up (FORCE=1 overrides,
# e.g. for a test run).
#
# Result: <target_dir>/
#   vfllcms.pgdump, eventmanager.pgdump   pg_dump -Fc (restore with pg_restore >= 12)
#   home.tar.gz      /home/scienceuli without venvs/.pyenv/.cache/node_modules
#                    (code incl. .git + uncommitted files, media/, static/,
#                    invoices/, sent_emails/, .env, local_settings.py, scripts)
#   etc.tar.gz       nginx + supervisor config
#   crontab.txt, info.txt, SHA256SUMS
set -euo pipefail

HOST="${BOHR_HOST:-scienceuli@bohr.science-and-more.com}"
TS="$(date +%Y%m%d-%H%M%S)"
DEST="${1:-$HOME/Backups/bohr-native-$TS}"

log() { printf '\n==> %s\n' "$*"; }

if ssh "$HOST" 'pgrep -f "gunicorn.*(gunicornvfll|gunicornemdev)\.sock" >/dev/null'; then
  if [[ "${FORCE:-0}" != 1 ]]; then
    echo "gunicorn still running on bohr - stop the apps first (see header) or set FORCE=1" >&2
    exit 1
  fi
  echo "WARNING: gunicorn still running, this is no write-frozen backup" >&2
fi

mkdir -p "$DEST"
cd "$DEST"
log "Backup into $DEST"

# Credentials stay on bohr: taken from the existing backup script / ~/.env.
log "pg_dump vfllcms"
ssh "$HOST" 'eval "$(grep "^export PG" ~/backup_vfllcms.sh)"; pg_dump --format=custom' > vfllcms.pgdump

log "pg_dump vfllfobi_dev (eventmanager)"
ssh "$HOST" 'set -a; . ~/.env; set +a;
  PGPASSWORD="$DB_PASSWORD" pg_dump --format=custom -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME"' > eventmanager.pgdump

log "tar /home/scienceuli"
ssh "$HOST" 'tar -C /home -czf - \
  --exclude=scienceuli/.pyenv --exclude=scienceuli/.cache \
  --exclude="scienceuli/vfllcms/vfllcmsenv*" \
  --exclude=node_modules --exclude=__pycache__ \
  scienceuli' > home.tar.gz

log "tar nginx + supervisor config"
# letsencrypt is root-only and gets reissued on the new system anyway
ssh "$HOST" 'tar -C / -czf - etc/nginx etc/supervisor 2>/dev/null || true' > etc.tar.gz

ssh "$HOST" 'crontab -l' > crontab.txt
ssh "$HOST" 'hostname; lsb_release -ds; date -Is; pg_dump --version;
  pgrep -af gunicorn | cut -c1-150 || echo "gunicorn: not running"' > info.txt

log "Verify"
pg_restore --list vfllcms.pgdump >/dev/null
pg_restore --list eventmanager.pgdump >/dev/null
for t in home etc; do tar -tzf "$t.tar.gz" >/dev/null; done
for d in vfllcms eventmanager; do
  printf '%-14s %5s tables  %s\n' "$d" \
    "$(pg_restore --list "$d.pgdump" | grep -c ' TABLE DATA ')" \
    "$(du -h "$d.pgdump" | cut -f1)"
done
tar -tzf home.tar.gz | grep -cE '^scienceuli/vfllcms/media/.+[^/]$' | sed 's/^/vfllcms media files:      /'
tar -tzf home.tar.gz | grep -cE '^scienceuli/eventmanager_dev/media/.+[^/]$' | sed 's/^/eventmanager media files: /'
shasum -a 256 ./*.pgdump ./*.tar.gz crontab.txt info.txt > SHA256SUMS
du -sh "$DEST"
log "Done: $DEST"
