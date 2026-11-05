# How to deploy: VFLL Wagtail CMS on bohr and hertz

Background on the stack: [README.md](README.md). Run every command **from
the repo root** (`~/Devel/Ansible-Build`), so `ansible.cfg` and
`.vault-pass` are found.

## 0. Prerequisites

- `ansible-galaxy collection install -r playbooks/vfllcms/requirements.yml`
- Secrets in `inventories/host_vars/bohr/vfllcms_vault.yml` and
  `inventories/host_vars/hertz/vfllcms_vault.yml` - both currently contain
  **placeholders only**. Rotate the real secrets first (the Google service
  account key and SECRET_KEY/VFLL_FACEBOOK_APP_SECRET/
  MEMBER_ADMIN_USER_SECRET/OPENAI_API_KEY were exposed in local shell/editor
  history during the upgrade work), then:
  `ansible-vault edit inventories/host_vars/bohr/vfllcms_vault.yml` (and the
  hertz one - use *different*, freshly generated values for staging, not
  copies of production secrets).
- `docker/env.example` and `rocketman/settings/container_settings.py` in
  the vfllcms repo document every variable the templates below render.

---

## bohr (production): host nginx + host Postgres

`bohr` has never had any Ansible playbook run against it - it's a
long-running, currently-serving-production box provisioned entirely
outside this repo (hand-created venv, supervisor, nginx, Postgres). Scope
stays deliberately narrow: this playbook only adds Docker and the vfllcms
container. It does **not** run the general `setup.yml` baseline (firewall,
SSH hardening, restic, ...) - that's a separate, larger decision for
another day.

### 1. One-time manual step: let the container reach the host's Postgres

On `bohr`, as a user who can edit the Postgres config:

```sh
sudo -u postgres psql -c "ALTER SYSTEM SET listen_addresses = '*';"
echo "host    vfllcms    vfllcms    172.16.0.0/12    scram-sha-256" \
  | sudo tee -a /etc/postgresql/*/main/pg_hba.conf
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

(`172.16.0.0/12` covers Docker's default bridge-network range; no Postgres
restart needed, `pg_reload_conf()` is enough.) Create the database/role if
they don't already exist, matching `vfllcms_db_name`/`vfllcms_db_user` in
`inventories/host_vars/bohr/vfllcms.yml` and the password in
`vfllcms_vault.yml`.

### 2. Deploy Docker + the container

```sh
ansible-playbook -i inventories playbooks/vfllcms/playbook.yml -l bohr
```

Confirm it's up before touching nginx/supervisor:

```sh
ssh scienceuli@bohr.science-and-more.com \
  "cd /opt/docker/vfllcms && sudo docker compose logs web | tail -50"
curl -I http://127.0.0.1:8010   # vfllcms_port, from bohr itself
```

### 3. Manual cutover (run this yourself, following these exact steps)

1. Stop the old bare-metal app: `supervisorctl stop vfllcms`.
2. Edit nginx's existing site config for `vfll.de`: change `proxy_pass`
   from the old unix socket to `http://127.0.0.1:8010`.
3. `sudo nginx -t && sudo systemctl reload nginx`.
4. Smoke-test: `curl -I https://vfll.de`, click around the live site, watch
   `sudo docker compose logs -f web` on `bohr`.

**Rollback**: revert the one `proxy_pass` line, reload nginx,
`supervisorctl start vfllcms` - the old venv stays in place, untouched.

---

## hertz (staging): containerized nginx + containerized, seeded Postgres

`hertz` already runs other apps through this repo (Nextcloud, Moodle,
Etherpad, Collabora) with a containerized nginx+certbot shared across all
of them (`nginx_proxies`). Unlike `bohr`, hertz has no host Postgres at all
(only MariaDB, for the other apps) - vfllcms gets its own Postgres
container here, seeded once from the restored production backup.

### 1. One-time manual step: stage the seed dump

```sh
ssh scienceuli@hertz.science-and-more.com "sudo mkdir -p /opt/docker/vfllcms/seed"
scp restore_data/postgres_vfllcms_*.pgdump \
  scienceuli@hertz.science-and-more.com:/tmp/vfllcms.pgdump
ssh scienceuli@hertz.science-and-more.com \
  "sudo mv /tmp/vfllcms.pgdump /opt/docker/vfllcms/seed/vfllcms.pgdump"
```

Must be in place **before** the first deploy below - the postgres image
only restores it the very first time it starts against an empty data
directory.

### 2. Deploy

```sh
task play -i inventories playbooks/vfllcms/playbook.yml -l hertz
```

Check the seed actually restored (first run only - watch for `pg_restore`
errors, not just that the container started):

```sh
ssh scienceuli@hertz.science-and-more.com \
  "cd /opt/docker/vfllcms && sudo docker compose logs db | tail -50"
```

### 3. Reverse proxy + TLS

`nginx -t` resolves the `vfllcms-web` upstream, so the app container must
already be running (step 2) before this:

```sh
ansible-playbook -i inventories playbooks/proxy.yml -l hertz
curl -I https://staging.vfll.de
```

### Reseeding later

To replace staging's database with a fresher production dump: stop the
stack (`sudo docker compose down` in `/opt/docker/vfllcms`), delete
`/opt/docker/vfllcms/db-data`, drop in the new dump at
`/opt/docker/vfllcms/seed/vfllcms.pgdump`, re-run the playbook.
