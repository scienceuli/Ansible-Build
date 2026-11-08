# VFLL Eventmanager on bohr

Two instances on the docker host `bohr` (Debian 13, since 2026-11-07),
each a docker compose stack behind the nginx container (`nginx` +
`certbot` roles, `nginx_proxies` in `inventories/host_vars/bohr/vars.yml`):

| | production | staging |
|---|---|---|
| inventory host | `bohr_eventmanager` | `bohr_eventmanager_staging` |
| domain | `https://veranstaltungskalender.vfll.de` | `https://staging.veranstaltungskalender.vfll.de` (basic auth `testing`, user `vfll`) |
| `eventmanager_name` = web container = nginx `dest_hostname` | `eventmanager` | `eventmanager-staging` |
| other containers | `eventmanager-db`, `-mjml` | `eventmanager-staging-db`, `-mjml` |
| compose project, image, directory | `eventmanager`, `eventmanager:latest`, `/opt/docker/eventmanager` | `eventmanager-staging`, … , `/opt/docker/eventmanager-staging` |
| mail | SMTP | file backend (`data/sent_emails`) |
| Mailgun, cron `fetch_emails` | yes | no |
| restic backup | yes | no |

The web containers join the docker network `science-and-more.com` and nginx
proxies to `<eventmanager_name>:8000`.

Before 2026-11-07 production ran natively on the old bohr (Ubuntu 20.04,
gunicorn under supervisor, `~/eventmanager_dev`, DB `vfllfobi_dev`), and
staging ran on faraday. See [HOW_TO_DEPLOY.md](HOW_TO_DEPLOY.md), "Migration
from the native bohr".

## Services

| Service     | What                                                        |
|-------------|-------------------------------------------------------------|
| `web`       | Django + gunicorn on port 8000 (no host port); runs migrate + collectstatic on start |
| `mjml`      | MJML TCP server for MJML newsletters                        |
| `db`        | Postgres 16, data in `/opt/docker/<name>/db-data`           |
| `mailqueue` | only with `eventmanager_mailqueue_autosend: true` (see below) |

The image is built on the host from the public GitHub repo
(`eventmanager_git_version`, default `main`). Push first, then re-run the
playbook. `Dockerfile`, `docker/` and `eventmanager/container_settings.py`
live in the eventmanager repo.

## Mail queue: sent by an admin, not automatically

Mails (invoices, confirmations, ...) are queued (django-mail-queue,
`MAILQUEUE_QUEUE_UP = True`) and **stay in the queue until an admin sends
them** in the mail queue admin. That is how the native bohr worked, and it is
set with `eventmanager_mailqueue_autosend: false` in both bohr instances.

With `eventmanager_mailqueue_autosend: true` (role default), a `mailqueue`
container runs `manage.py send_queued_messages` every 60 s. Switching back
to `false` removes that container (`remove_orphans`). Before switching to
`true`, check the backlog: every unsent mail in the queue goes out right
away.

    sudo docker exec eventmanager-db psql -U eventmanager eventmanager \
      -c "select sent, count(*) from mailqueue_mailermessage group by 1"

## Deploy

Step by step, from a fresh server: [HOW_TO_DEPLOY.md](HOW_TO_DEPLOY.md).

    uv run ansible-galaxy collection install -r playbooks/eventmanager/requirements.yml
    uv run ansible-playbook -i inventories playbooks/eventmanager/playbook.yml -l bohr,bohr_eventmanager
    uv run ansible-playbook -i inventories playbooks/eventmanager/playbook.yml -l bohr,bohr_eventmanager_staging

Always limit to the instance(s) plus their docker host `bohr`: the first and
last play (docker network, htpasswd/certbot/nginx) run on the docker host.

## Configuration

- `inventories/host_vars/bohr_eventmanager/` and
  `inventories/host_vars/bohr_eventmanager_staging/`: `vars.yml` (domain,
  network, mail, integrations, cron jobs, `eventmanager_mailqueue_autosend`)
  and `vault.yml`. Each instance has its own `SECRET_KEY`.
  Staging shares production's `ENCRYPT_KEY`, because the encrypted newsletter
  tokens in the restored database depend on it.
- `inventories/host_vars/bohr/vars.yml`: nginx/certbot (`nginx_proxies`,
  `nginx_extra_volumes`), basic auth (`htpasswd_*`) and restic
  (`restic_backup_set`) of the docker host.

All role variables with defaults: `roles/eventmanager/defaults/main.yml`.
The role renders them into `/opt/docker/<name>/.env`, which
`eventmanager.container_settings` reads.

Vault values must be the plain value. Don't wrap them in quotes (`'587'`,
`'''key'''`), and keep `$` out of them (compose interpolates it in env
files). Compose rejects quoted values with
`unexpected character "'" in variable name` - and prints the value in the
error message.

## Data

`/opt/docker/<name>/data` is mounted at `/data`:

- `static/` - collectstatic output, served by the nginx container
- `media/` - public uploads, served by the nginx container. nginx answers 404
  for `mailqueue-attachments/` and, as defence in depth, for the old private
  paths (`invoices/`, `confirmations/`, `uploaded_private_documents/`, `stornos/`)
- `private/` - invoices, confirmations, private documents
  (django-private-storage, `PRIVATE_STORAGE_ROOT`). nginx never mounts it,
  only Django serves it (`/private-media/`) after a permission check.
- `sent_emails/` - file mail backend output (staging; native history on production)

## Backup & restore

restic, repo `bohr` on backup.science-and-more.com, **production only**,
configured in `inventories/host_vars/bohr/vars.yml` (`restic_backup_set`),
applied with `playbooks/setup.yml -t restic -l bohr`. Nightly on bohr:

| Time | Job | Snapshot tag |
|---|---|---|
| 02:06 | `pg_dump` of `eventmanager` → `/var/backup/eventmanager-db/` | `eventmanager`, `postgres` |
| 02:25 | `/opt/docker/eventmanager/data` (media, private, sent_emails, static) | `eventmanager`, `files` |
| 23:36 | `forget --prune` (14 last, 14 daily, 4 weekly, 3 monthly) | |

On bohr (`restic-main` = restic with repo and password preset). Combine
tags with a comma: `--tag a,b` means a **and** b, while `--tag a --tag b`
means a **or** b (`latest` could then pick the other app's dump, or the
files snapshot):

    sudo restic-main snapshots --tag eventmanager
    sudo restic-main restore latest --tag eventmanager,postgres --target /tmp/restore
    sudo restic-main restore latest --tag eventmanager,files --target /tmp/restore

The nightly dump is **plain SQL** (`docker-postgres-backup` runs `pg_dump`
without `-Fc`): `/tmp/restore/var/backup/eventmanager-db/eventmanager.sql`. Load it with
`psql`, not with `-e eventmanager_restore_dump=...` (that runs `pg_restore`, which
rejects plain SQL dumps). With web stopped:

    cd /opt/docker/eventmanager
    sudo docker compose stop web       # + mailqueue with eventmanager_mailqueue_autosend: true
    sudo docker exec eventmanager-db sh -c \
      'dropdb -U eventmanager --maintenance-db=postgres --if-exists --force eventmanager \
       && createdb -U eventmanager --maintenance-db=postgres -O eventmanager eventmanager'
    sudo cat /tmp/restore/var/backup/eventmanager-db/eventmanager.sql \
      | sudo docker exec -i eventmanager-db \
        psql -U eventmanager -d eventmanager -v ON_ERROR_STOP=1 --single-transaction -q
    sudo docker compose start web      # only if the restore succeeded

Files: `sudo rsync -a /tmp/restore/opt/docker/eventmanager/data/ /opt/docker/eventmanager/data/`,
then `chown -R 1000:1000` on `media/`, `private/`, `sent_emails/`. Remove `/tmp/restore` afterwards.

`-e eventmanager_restore_dump=<dump on your Mac>` is for `pg_dump -Fc` archives
(e.g. a production dump for staging): see HOW_TO_DEPLOY.md, "Restore a database dump".

## First run on a fresh database

    ssh -t scienceuli@bohr.science-and-more.com \
      "sudo docker exec -it eventmanager python manage.py createsuperuser"

The user groups are required: templates check membership with `has_group`,
and a missing group gives an Internal Server Error on `/`:

    sudo docker exec eventmanager python manage.py loaddata \
      data/initial_groups.json data/initial_email_templates.json
    sudo docker exec eventmanager python manage.py shell -c \
      "from django.contrib.auth.models import Group; Group.objects.get_or_create(name='newsletter')"

Set the domain of `Site` 1 in the admin (Sites) to the real domain.

## Useful commands

    cd /opt/docker/eventmanager            # or eventmanager-staging
    sudo docker compose logs -f web
    sudo docker compose exec web python manage.py shell
    sudo docker compose exec db psql -U eventmanager eventmanager
    journalctl -t eventmanager-cron        # fetch_emails (production)
