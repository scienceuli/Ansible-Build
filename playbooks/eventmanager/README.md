# VFLL Eventmanager on faraday

Staging instance `eventmanager-staging` on faraday:
`https://staging.veranstaltungskalender.vfll.de` (basic auth `testing`, user
`vfll`). Docker compose stack in `/opt/docker/eventmanager-staging`, fronted by
the nginx container (`nginx` + `certbot` roles, like on backup). The web
container joins the docker network `science-and-more.com` and nginx proxies to
`eventmanager-staging:8000`.

## Instances

`eventmanager_name` (role `eventmanager`, default `eventmanager`) names one
instance, so production and staging can share a host:

| | production | staging (faraday, since 2026-11-06) |
|---|---|---|
| `eventmanager_name` | `eventmanager` | `eventmanager-staging` |
| web container = nginx `dest_hostname` | `eventmanager` | `eventmanager-staging` |
| other containers | `eventmanager-db`, `-mjml`, `-mailqueue` | `eventmanager-staging-db`, `-mjml`, `-mailqueue` |
| compose project, image, directory | `eventmanager`, `eventmanager:latest`, `/opt/docker/eventmanager` | `eventmanager-staging`, … , `/opt/docker/eventmanager-staging` |
| domain | `veranstaltungskalender.vfll.de` | `staging.veranstaltungskalender.vfll.de` |

Each instance is one inventory host (here `faraday_eventmanager_staging`) with its own
`eventmanager_*` vars; on the docker host its own `nginx_proxies` entry,
`nginx_extra_volumes` (`/srv/<name>/static`, `/srv/<name>/media`) and
`restic_backup_set` entries.

| Service     | What                                                        |
|-------------|-------------------------------------------------------------|
| `web`       | Django + gunicorn, `eventmanager-staging:8000` (no host port); runs migrate + collectstatic on start |
| `mailqueue` | `manage.py send_queued_messages` every 60 s (django-mail-queue) |
| `mjml`      | MJML TCP server for MJML newsletters                        |
| `db`        | Postgres 16, data in `/opt/docker/eventmanager-staging/db-data`     |

The image is built on the host from the public GitHub repo
(`eventmanager_git_version`, default `main`): push first, then re-run.
`Dockerfile`, `docker/` and `eventmanager/container_settings.py` live in the
eventmanager repo.

## Deploy

Step by step from a fresh server: [HOW_TO_DEPLOY.md](HOW_TO_DEPLOY.md).

    ansible-galaxy collection install -r playbooks/eventmanager/requirements.yml
    ansible-playbook -i inventories playbooks/eventmanager/playbook.yml

## Configuration

Two inventory hosts for the same server:

- `inventories/host_vars/faraday_eventmanager_staging/`: `vars.yml` (domain, docker
  network, mail backend, ...) and `vault.yml` (Django `SECRET_KEY`, Fernet
  `ENCRYPT_KEY`, Postgres password).
- `inventories/host_vars/faraday/vars.yml`: the nginx/certbot containers -
  `nginx_proxies` (proxy, `/static/`, `/media/`) and `nginx_extra_volumes`
  (static/ and media/ mounted read-only into nginx).
All role variables with defaults: `roles/eventmanager/defaults/main.yml`.
The role renders them into `/opt/docker/eventmanager-staging/.env`, which
`eventmanager.container_settings` reads. Keep `$` out of secret values
(compose interpolates it in env files).

Mail: faraday uses the file backend by default, so nothing leaves the
server - mails land in `/opt/docker/eventmanager-staging/data/sent_emails`.

## Data

`/opt/docker/eventmanager-staging/data` is mounted at `/data`:

- `static/` - collectstatic output, served by the nginx container
- `media/` - public uploads, served by the nginx container (except `mailqueue-attachments/`)
- `private/` - invoices, confirmations, private documents; only served by
  Django (`/private-media/`) after a permission check
- `sent_emails/` - file mail backend output

## Backup & restore

restic, repo `faraday` on backup.science-and-more.com, configured in
`inventories/host_vars/faraday/vars.yml` (`restic_backup_set`), applied with
`playbooks/setup.yml -t restic -l faraday`. Nightly on faraday:

| Time | Job | Snapshot tag |
|---|---|---|
| 02:06 | `pg_dump` of `eventmanager` → `/var/backup/eventmanager-staging-db/eventmanager.sql` | `postgres` |
| 02:25 | `/opt/docker/eventmanager-staging/data` (media, private, sent_emails, static) | `files` |
| 23:xx | `forget --prune` (14 last, 14 daily, 4 weekly, 3 monthly) | |

On faraday (`restic-main` = restic with repo and password preset):

    sudo restic-main snapshots --tag eventmanager
    # database: restore the dump, then replace the live DB with it
    sudo restic-main restore latest --tag postgres --target /tmp/restore
    sudo docker-postgres-restore -c eventmanager-staging-db -d eventmanager -r \
      -f /tmp/restore/var/backup/eventmanager-staging-db/eventmanager.sql
    # files: restore, then copy back what's needed
    sudo restic-main restore latest --tag files --target /tmp/restore
    sudo rsync -a /tmp/restore/opt/docker/eventmanager-staging/data/ /opt/docker/eventmanager-staging/data/

Stop `web` and `mailqueue` (`sudo docker compose stop web mailqueue`) before
replacing the database, start them again afterwards.

## First run on a fresh database

    ssh -t scienceuli@faraday.science-and-more.com \
      "sudo docker exec -it eventmanager-staging python manage.py createsuperuser"

Optional initial data shipped in the repo:

    sudo docker exec eventmanager-staging python manage.py loaddata \
      data/initial_groups.json data/initial_email_templates.json

Set the domain of `Site` 1 in the admin (Sites) to the real domain.

## Useful commands

    cd /opt/docker/eventmanager-staging
    sudo docker compose logs -f web
    sudo docker compose exec web python manage.py shell
    sudo docker compose exec db psql -U eventmanager eventmanager
