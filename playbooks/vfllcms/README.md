# VFLL Wagtail CMS on bohr

Two instances on the docker host `bohr` (Debian 13, since 2026-11-07),
each a docker compose stack behind the nginx container (`nginx` +
`certbot` roles, `nginx_proxies` in `inventories/host_vars/bohr/vars.yml`):

| | production | staging |
|---|---|---|
| inventory host | `bohr_vfllcms` | `bohr_vfllcms_staging` |
| domain | `https://vfll.de` (`www.vfll.de` → 301) | `https://staging.vfll.de` (basic auth `testing`, user `vfll`) |
| `vfllcms_name` | `vfllcms` | `vfllcms-staging` |
| containers | `vfllcms-web` (= nginx `dest_hostname`), `vfllcms-db` | `vfllcms-staging-web`, `vfllcms-staging-db` |
| compose project, image, directory | `vfllcms`, `vfllcms:latest`, `/opt/docker/vfllcms` | `vfllcms-staging`, … , `/opt/docker/vfllcms-staging` |
| mail | SMTP | file backend (`data/sent_emails`) |
| cron `get_events` 06:00, `get_blog` 00:00 | yes | no |
| restic backup | yes | no |

Before 2026-11-07 production ran natively on the old bohr (Ubuntu 20.04,
gunicorn under supervisor, `~/vfllcms`, host Postgres 12), and staging ran on
hertz. See [HOW_TO_DEPLOY.md](HOW_TO_DEPLOY.md), "Migration from the native
bohr".

| Service | What |
|---|---|
| `web` | Django/Wagtail + gunicorn on port 8000 (no host port); runs migrate + collectstatic on start |
| `db`  | Postgres 16, data in `/opt/docker/<name>/db-data` |

The image is built on the host from the **private** GitHub repo
`git@github.com:scienceuli/vfllcms.git` (`vfllcms_git_version`, default
`main`) with the read-only deploy key `/root/.ssh/vfllcms_deploy_key`
(GitHub: repo Settings → Deploy keys, "bohr (ansible)"). Push first, then
re-run the playbook. `Dockerfile`, `docker/` and
`rocketman/settings/container_settings.py` live in the vfllcms repo.

The role can also run against a host Postgres or a host nginx
(`vfllcms_db_containerized`, `vfllcms_nginx_containerized` = false, see
`roles/vfllcms/defaults/main.yml`). bohr uses neither.

## Deploy

Step by step, from a fresh server: [HOW_TO_DEPLOY.md](HOW_TO_DEPLOY.md).

    uv run ansible-galaxy collection install -r playbooks/vfllcms/requirements.yml
    uv run ansible-playbook -i inventories playbooks/vfllcms/playbook.yml -l bohr,bohr_vfllcms
    uv run ansible-playbook -i inventories playbooks/vfllcms/playbook.yml -l bohr,bohr_vfllcms_staging

Always limit to the instance(s) plus their docker host `bohr`: the first and
last play (docker network, htpasswd/certbot/nginx) run on the docker host.

## Configuration

- `inventories/host_vars/bohr_vfllcms/` and
  `inventories/host_vars/bohr_vfllcms_staging/`: `vars.yml` (domain, network,
  mail, integrations, `vfllcms_cron_jobs`) and `vault.yml` (`SECRET_KEY`, DB
  password; production also SMTP, Facebook, OpenAI, member admin, Google
  service account).
- `inventories/host_vars/bohr/vars.yml`: nginx/certbot (`nginx_proxies`,
  `nginx_extra_volumes`), basic auth and restic of the docker host.

All role variables with defaults: `roles/vfllcms/defaults/main.yml`. The
role renders them into `/opt/docker/<name>/.env`, which
`rocketman.settings.container_settings` reads. Keep `$` out of secret
values (compose interpolates it in env files), and don't wrap them in quotes.

`vault_vfllcms_google_credentials` is the Google service account JSON (all
10 keys, incl. `private_key`). Ansible parses it into a dict, and `env.j2`
writes it as one compact JSON line: an env file ends a value at the first
newline.

## Data

`/opt/docker/<name>/data` is mounted at `/data`:

- `static/` - collectstatic output, served by the nginx container
- `media/` - Wagtail uploads (`images/`, `original_images/`, `documents/`,
  `svg/`, ...). As on the native bohr, nginx serves only `/media/images/` and
  `/media/svg/` directly and answers 404 for the rest. Documents go through
  Wagtail (`/documents/<id>/<file>`), which checks collection privacy.

## Periodic jobs

`vfllcms_cron_jobs` (production) runs on bohr as
`docker exec vfllcms-web uv run manage.py <command>`. Output goes to
syslog: `journalctl -t vfllcms-cron`.

| Job | When | What |
|---|---|---|
| `get_events` | 06:00 | replaces all `Event`s with the next 300 days from the eventmanager API (`EVENT_API_URL` = https://veranstaltungskalender.vfll.de) |
| `get_blog` | 00:00 | imports the posts of https://lektorenverband.de/wp-json/wp/v2/posts |

These replace the native `get_events.sh`/`get_blog.sh` (kept in
`~/hetzner_nc/Backups/vfll_backups/`).

## Backup & restore

restic, repo `bohr` on backup.science-and-more.com, **production only**,
configured in `inventories/host_vars/bohr/vars.yml`, applied with
`playbooks/setup.yml -t restic -l bohr`. Nightly on bohr:

| Time | Job | Snapshot tag |
|---|---|---|
| 02:23 | `pg_dump` of `vfllcms` → `/var/backup/vfllcms-db/` | `vfllcms`, `postgres` |
| 02:57 | `/opt/docker/vfllcms/data` (media, static) | `vfllcms`, `files` |
| 23:36 | `forget --prune` (14 last, 14 daily, 4 weekly, 3 monthly) | |

    sudo restic-main snapshots --tag vfllcms
    sudo restic-main restore latest --tag postgres --tag vfllcms --target /tmp/restore

To put a database dump back, use the playbook with
`-e vfllcms_restore_dump=<dump on your Mac>`: see HOW_TO_DEPLOY.md.

## First run on a fresh database

    ssh -t scienceuli@bohr.science-and-more.com \
      "sudo docker exec -it vfllcms-web uv run manage.py createsuperuser"

Set the domain of `Site` 1 in the admin (Sites) to the real domain.

## Useful commands

    cd /opt/docker/vfllcms                 # or vfllcms-staging
    sudo docker compose logs -f web
    sudo docker compose exec web uv run manage.py shell
    sudo docker compose exec db psql -U vfllcms vfllcms
    journalctl -t vfllcms-cron
