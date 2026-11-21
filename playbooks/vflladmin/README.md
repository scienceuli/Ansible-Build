# VFLL member administration (vflladmin) on bohr

Django app from the **private** repo `github.com/scienceuli/vflladmin_project`,
production at `https://memberadmin.vfll.de`. A docker compose stack on the
docker host `bohr` (next to vfllcms and the eventmanager) behind the nginx container (`nginx` + `certbot` roles,
`nginx_proxies` in `inventories/host_vars/bohr/vars.yml`).

| | |
|---|---|
| inventory host | `bohr_vflladmin` (groups `vflladmin`, `vflladmin_docker_hosts`: `bohr`) |
| `vflladmin_name` = web container = nginx `dest_hostname` | `vflladmin` |
| other containers | `vflladmin-db` (Postgres 16), `vflladmin-redis`, `vflladmin-worker` (celery) |
| directory | `/opt/docker/vflladmin` (`src/`, `data/`, `db-data/`, `deploy/`, `.env`) |

The VFLL Eventmanager (same host) uses the API (`/api/login`,
`/members/api/emails/`, see `host_vars/bohr_eventmanager`).

Before 2026-11 it ran natively on euler (Ubuntu 20.04, gunicorn + celery
under supervisor, Postgres 12, `~/vflladmin_project`, media in
`/mnt/storagespace/vflladmin_project/media`).

## Services

| Service  | What |
|----------|------|
| `web`    | Django + gunicorn on port 8000 (no host port); runs `fix_legacy_migration_history`, `migrate` and `collectstatic` on start |
| `worker` | celery worker: invoice PDFs and invoice mails in the background |
| `redis`  | celery broker, nothing persistent |
| `db`     | Postgres 16, data in `/opt/docker/vflladmin/db-data` |

`Dockerfile`, `docker/` and `vflladmin/settings/container.py` live in the
app repo. The image is built on bohr from `vflladmin_git_version`
(default `main`): push first, then re-run the playbook.

## Files

`/opt/docker/vflladmin/data` is mounted at `/data`:

- `static/` - collectstatic output, served by the nginx container
- `media/` - member documents, invoices, mail attachments. **Private**:
  nginx never mounts it, Django serves the files after a permission check.
- `backup/` - output of `manage.py dbbackup` (not scheduled, restic dumps the DB)

## Deploy

    uv run ansible-galaxy collection install -r playbooks/vflladmin/requirements.yml
    uv run ansible-playbook -i inventories playbooks/vflladmin/playbook.yml -l bohr,bohr_vflladmin

**First run:** the role generates a deploy key on bohr and fails with its
public key. Add it on GitHub as a read-only deploy key (repo > Settings >
Deploy keys), then run the playbook again.

## Configuration

- `inventories/host_vars/bohr_vflladmin/vars.yml` (domain, mail, ...) and
  `vault.yml` (ansible-vault encrypted) with
  `vault_vflladmin_secret_key`, `vault_vflladmin_db_password`,
  `vault_vflladmin_email_host`, `vault_vflladmin_email_host_user`,
  `vault_vflladmin_email_host_password`, `vault_vflladmin_mailtrap_api_token`,
  `vault_vflladmin_mailtrap_inbox_id`. Take the values from euler's
  `~/vflladmin_project/.env`; keep the `SECRET_KEY` (sessions, password
  reset links). The DB password is new.
- `inventories/host_vars/bohr/vars.yml`: nginx (`nginx_proxies`,
  `nginx_extra_volumes`) and restic (`restic_backup_set`).

All role variables with defaults: `roles/vflladmin/defaults/main.yml`.

Vault values must be the plain value: no quotes, no `$` (compose
interpolates it in env files).

## Migration from euler

1. Announce a short downtime; the Eventmanager API is unavailable meanwhile.
2. On euler: stop the app (`sudo supervisorctl stop vflladmin vflladmincelery`),
   then dump the database and pack the media:

       pg_dump -Fc -U vflladmin -h localhost vflladmin > vflladmin.pgdump
       tar -czf media.tar.gz -C /mnt/storagespace/vflladmin_project media

   Copy both to the control machine.
3. Lower the TTL of `memberadmin.vfll.de` in advance, then point it to bohr.
4. Deploy with the dump:

       uv run ansible-playbook -i inventories playbooks/vflladmin/playbook.yml \
         -l bohr,bohr_vflladmin -e vflladmin_restore_dump=/path/to/vflladmin.pgdump

   The web container repairs euler's migration history
   (`fix_legacy_migration_history`) and migrates the database to the
   current code.
5. Media: copy `media.tar.gz` to bohr and unpack it into the data dir:

       sudo tar -xzf media.tar.gz -C /opt/docker/vflladmin/data
       sudo chown -R 1000:1000 /opt/docker/vflladmin/data/media

6. Check: login, member list, a member document, an invoice PDF, the
   Eventmanager's member e-mail sync. Then stop euler's services for good.

## Backup & restore

restic, repo `bohr` on backup.science-and-more.com, configured in
`inventories/host_vars/bohr/vars.yml`, applied with
`playbooks/setup.yml -t restic -l bohr`. Nightly at 02:xx: `pg_dump` of
`vflladmin` (tags `vflladmin,postgres`) and `/opt/docker/vflladmin/data`
(tags `vflladmin,files`).

    sudo restic-main snapshots --tag vflladmin
    sudo restic-main restore latest --tag vflladmin,postgres --target /tmp/restore
