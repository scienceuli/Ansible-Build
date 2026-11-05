# VFLL Wagtail CMS on bohr (production) and hertz (staging)

Docker compose stack, `/opt/docker/vfllcms`, on two hosts with different
topologies:

| | `bohr` (production) | `hertz` (staging) |
|---|---|---|
| Public URL | `https://vfll.de` | `https://staging.vfll.de` |
| nginx | host-managed, un-dockerized (manual `proxy_pass`) | containerized (`nginx_proxies`) |
| Postgres | host-managed, un-dockerized | containerized, seeded once from the restored production dump |
| Web reachable as | `127.0.0.1:{{ vfllcms_port }}` | `vfllcms-web:8000` on the shared docker network |

| Service | What |
|---|---|
| `web` | Django + gunicorn; runs migrate + collectstatic on start |
| `db`  | Postgres 16, `hertz` only - data in `/opt/docker/vfllcms/db-data` |

The image is built on the host from the public GitHub repo
(`vfllcms_git_version`, default `main`): push first, then re-run.
`Dockerfile`, `docker/` and `rocketman/settings/container_settings.py` live
in the vfllcms repo.

## Deploy

Step by step, including the manual prerequisites each host still needs:
[HOW_TO_DEPLOY.md](HOW_TO_DEPLOY.md).

    ansible-galaxy collection install -r playbooks/vfllcms/requirements.yml
    ansible-playbook -i inventories playbooks/vfllcms/playbook.yml -l bohr
    ansible-playbook -i inventories playbooks/vfllcms/playbook.yml -l hertz
    ansible-playbook -i inventories playbooks/proxy.yml -l hertz   # picks up nginx_proxies

## Configuration

- `inventories/host_vars/bohr/vfllcms.yml` + `vfllcms_vault.yml` - production
  (domain, host Postgres/mail credentials).
- `inventories/host_vars/hertz/vfllcms.yml` + `vfllcms_vault.yml` - staging
  (domain, `vfllcms_nginx_containerized`/`vfllcms_network`,
  `vfllcms_db_containerized`/`vfllcms_db_seed_dump`).
- `inventories/host_vars/hertz/vars.yml`: the nginx container -
  `nginx_proxies` (proxy, `/static/`, `/media/`) and `nginx_extra_volumes`.
  Nothing templated on `bohr` for nginx - see HOW_TO_DEPLOY.md.

All role variables with defaults: `roles/vfllcms/defaults/main.yml`. The
role renders them into `/opt/docker/vfllcms/.env`, which
`rocketman.settings.container_settings` reads. Keep `$` out of secret
values (compose interpolates it in env files).

Mail: staging uses the file backend by default, so nothing leaves the
server - mails land in `/opt/docker/vfllcms/data/sent_emails`.

## Data

`/opt/docker/vfllcms/data` is mounted at `/data`:

- `static/` - collectstatic output
- `media/` - uploads (documents, images)

## Database seeding (hertz only)

The official `postgres` image only runs
`/docker-entrypoint-initdb.d/*.sh` the very first time it starts against an
empty data directory. `roles/vfllcms/files/seed-restore.sh` runs
`pg_restore` against whatever file `vfllcms_db_seed_dump` points at on the
host (default: `/opt/docker/vfllcms/seed/vfllcms.pgdump` - copy the dump
there, e.g. `restore_data/postgres_vfllcms_*.pgdump`, before the first
deploy). To reseed later: stop the stack, `rm -rf`
`{{ vfllcms_db_data_dir }}`, deploy again.

## First run on a fresh database (hertz)

    ssh -t scienceuli@hertz.science-and-more.com \
      "sudo docker exec -it vfllcms-web uv run manage.py createsuperuser"

Set the domain of `Site` 1 in the admin (Sites) to `staging.vfll.de`.

## Useful commands

    cd /opt/docker/vfllcms
    sudo docker compose logs -f web
    sudo docker compose exec web uv run manage.py shell
    sudo docker compose exec db psql -U vfllcms vfllcms   # hertz only
