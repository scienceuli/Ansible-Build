# VFLL Eventmanager on faraday

Docker compose stack in `/opt/docker/eventmanager`, fronted by the nginx
container (`nginx` + `certbot` roles, like on backup):
`https://faraday.science-and-more.com`. The web container joins the docker
network `science-and-more.com` and nginx proxies to `eventmanager-web:8000`.

| Service     | What                                                        |
|-------------|-------------------------------------------------------------|
| `web`       | Django + gunicorn, `eventmanager-web:8000` (no host port); runs migrate + collectstatic on start |
| `mailqueue` | `manage.py send_queued_messages` every 60 s (django-mail-queue) |
| `mjml`      | MJML TCP server for MJML newsletters                        |
| `db`        | Postgres 16, data in `/opt/docker/eventmanager/db-data`     |

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

- `inventories/host_vars/faraday_eventmanager/`: `vars.yml` (domain, docker
  network, mail backend, ...) and `vault.yml` (Django `SECRET_KEY`, Fernet
  `ENCRYPT_KEY`, Postgres password).
- `inventories/host_vars/faraday/vars.yml`: the nginx/certbot containers -
  `nginx_proxies` (proxy, `/static/`, `/media/`) and `nginx_extra_volumes`
  (static/ and media/ mounted read-only into nginx).
All role variables with defaults: `roles/eventmanager/defaults/main.yml`.
The role renders them into `/opt/docker/eventmanager/.env`, which
`eventmanager.container_settings` reads. Keep `$` out of secret values
(compose interpolates it in env files).

Mail: faraday uses the file backend by default, so nothing leaves the
server - mails land in `/opt/docker/eventmanager/data/sent_emails`.

## Data

`/opt/docker/eventmanager/data` is mounted at `/data`:

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
| 02:06 | `pg_dump` of `eventmanager` → `/var/backup/eventmanager-db/eventmanager.sql` | `postgres` |
| 02:25 | `/opt/docker/eventmanager/data` (media, private, sent_emails, static) | `files` |
| 23:xx | `forget --prune` (14 last, 14 daily, 4 weekly, 3 monthly) | |

On faraday (`restic-main` = restic with repo and password preset):

    sudo restic-main snapshots --tag eventmanager
    # database: restore the dump, then replace the live DB with it
    sudo restic-main restore latest --tag postgres --target /tmp/restore
    sudo docker-postgres-restore -c eventmanager-db -d eventmanager -r \
      -f /tmp/restore/var/backup/eventmanager-db/eventmanager.sql
    # files: restore, then copy back what's needed
    sudo restic-main restore latest --tag files --target /tmp/restore
    sudo rsync -a /tmp/restore/opt/docker/eventmanager/data/ /opt/docker/eventmanager/data/

Stop `web` and `mailqueue` (`sudo docker compose stop web mailqueue`) before
replacing the database, start them again afterwards.

## First run on a fresh database

    ssh -t scienceuli@faraday.science-and-more.com \
      "sudo docker exec -it eventmanager-web python manage.py createsuperuser"

Optional initial data shipped in the repo:

    sudo docker exec eventmanager-web python manage.py loaddata \
      data/initial_groups.json data/initial_email_templates.json

Set the domain of `Site` 1 in the admin (Sites) to the real domain.

## Useful commands

    cd /opt/docker/eventmanager
    sudo docker compose logs -f web
    sudo docker compose exec web python manage.py shell
    sudo docker compose exec db psql -U eventmanager eventmanager
