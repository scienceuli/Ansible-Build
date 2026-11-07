# How to deploy: VFLL Wagtail CMS on bohr

From a freshly installed bohr (Netcup, Debian 13) to `https://vfll.de` and
the staging instance. Background on the stack: [README.md](README.md).

Three inventory hosts point at the same server:

| Inventory host | What it's for | Vars |
|---|---|---|
| `bohr` | the server: users, packages, firewall, Docker, nginx + certbot containers, restic | `inventories/host_vars/bohr/`, `group_vars/setup`, `group_vars/debian13.yml` |
| `bohr_vfllcms` | production stack in `/opt/docker/vfllcms` | `inventories/host_vars/bohr_vfllcms/` |
| `bohr_vfllcms_staging` | staging stack in `/opt/docker/vfllcms-staging` | `inventories/host_vars/bohr_vfllcms_staging/` |

The VFLL Eventmanager runs on the same server. Run every command **from the
repo root** (`~/Devel/Ansible-Build`) and always with `-l` as shown.

## 0. Prerequisites

- DNS at all-inkl (KAS): `vfll.de`, `www.vfll.de`, `staging.vfll.de` →
  `94.16.123.175` (bohr).
- Secrets in `inventories/host_vars/bohr_vfllcms*/vault.yml` - plain values,
  no quotes, no `$` (README, "Configuration").
- Ansible collections: `uv run ansible-galaxy collection install -r playbooks/vfllcms/requirements.yml`

## 1.-3. Server: SSH host key, bootstrap, setup

Same as for the eventmanager, once per server:
[../eventmanager/HOW_TO_DEPLOY.md](../eventmanager/HOW_TO_DEPLOY.md),
steps 1-3 (`bootstrap.yml -l bohr`, then `setup.yml -l bohr --skip-tags restic`).

## 4. GitHub deploy key (private repo)

Once per server. Generate the key on bohr where the vars expect it
(`vfllcms_git_key_file`):

```sh
ssh scienceuli@bohr.science-and-more.com \
  'sudo ssh-keygen -q -t ed25519 -N "" -C "bohr (ansible) vfllcms deploy key" -f /root/.ssh/vfllcms_deploy_key; sudo cat /root/.ssh/vfllcms_deploy_key.pub' > /tmp/bohr_vfllcms.pub
gh repo deploy-key add /tmp/bohr_vfllcms.pub -R scienceuli/vfllcms --title "bohr (ansible)"
ssh scienceuli@bohr.science-and-more.com \
  'sudo ssh -i /root/.ssh/vfllcms_deploy_key -o StrictHostKeyChecking=accept-new -T git@github.com'
# → "Hi scienceuli/vfllcms! You've successfully authenticated"
```

(read-only by default; or add it by hand: repo Settings → Deploy keys). After
a reinstall, delete the old "bohr (ansible)" key on GitHub.

## 5. Deploy both instances (without nginx)

```sh
uv run ansible-playbook -i inventories playbooks/vfllcms/playbook.yml \
  -l bohr,bohr_vfllcms,bohr_vfllcms_staging --skip-tags htpasswd,certbot,nginx \
  -e vfllcms_restore_dump=$HOME/path/to/vfllcms.pgdump
```

Clones the repo, builds the image, starts `db` and `web`, restores the dump
(role `compose_pg_restore`: stops web, drops/recreates the db, restores in
one transaction, starts web, which migrates). Leave out the `-e` for an empty
database (README, "First run on a fresh database"). Check that web is up:

```sh
ssh scienceuli@bohr.science-and-more.com 'docker logs vfllcms-web 2>&1 | grep "Listening at"'
```

## 6. Media

Uploads aren't in the dump: copy `media/` into
`/opt/docker/<name>/data/media/` (owner `1000:1000`), see "Migration from the
native bohr", or restore it from restic.

## 7. Reverse proxy + TLS, backup

Once the vfllcms **and** eventmanager instances are deployed (nginx
bind-mounts the data dirs of all of them):

```sh
uv run ansible-playbook -i inventories playbooks/vfllcms/playbook.yml -l bohr -t htpasswd,certbot,nginx
uv run ansible-playbook -i inventories playbooks/setup.yml -l bohr -t restic
```

Check:

```sh
curl -I https://vfll.de                     # 200
curl -I https://www.vfll.de                 # 301 → https://vfll.de/
curl -I https://staging.vfll.de             # 401 (basic auth)
curl -I https://vfll.de/media/documents/    # 404 (documents only via /documents/...)
```

## Later deployments

- **New app version:** push to `main` of the vfllcms repo, then
  `uv run ansible-playbook -i inventories playbooks/vfllcms/playbook.yml -l bohr,bohr_vfllcms_staging`,
  test on staging, then the same with `bohr_vfllcms`.
- **Refresh staging from production:** dump production on bohr
  (`sudo docker exec vfllcms-db pg_dump -Fc -U vfllcms vfllcms > vfllcms.pgdump`),
  copy it to your Mac, then step 5 for `bohr_vfllcms_staging` only.
- **Only proxy config changed** (`host_vars/bohr/vars.yml`): step 7, first command, with `-t nginx`.

## Migration from the native bohr (2026-11-07)

How production moved from the hand-installed bohr (Ubuntu 20.04, supervisor,
host Postgres 12) to the reinstalled one, for reference:

1. **Freeze and final backup:** apps stopped
   (`sudo supervisorctl stop vfllcms eventmanager_dev`, crontab commented
   out), then `playbooks/bohr_migration/backup_bohr_native.sh <dir>` →
   `~/hetzner_nc/Backups/vfll_backups/final/` (`vfllcms.pgdump`,
   `home.tar.gz` with `vfllcms/media/`).
2. Reinstall, server steps, deploy key, step 5 with
   `-e vfllcms_restore_dump=.../final/vfllcms.pgdump`. The migrations bring the
   native database up to the current code (Wagtail 4).
3. **Media**, the same tree for both instances:
   ```sh
   tar -xzf final/home.tar.gz scienceuli/vfllcms/media
   for n in vfllcms vfllcms-staging; do
     rsync -a --rsync-path="sudo rsync" scienceuli/vfllcms/media/ \
       scienceuli@bohr.science-and-more.com:/opt/docker/$n/data/media/
     ssh scienceuli@bohr.science-and-more.com "sudo chown -R 1000:1000 /opt/docker/$n/data/media"
   done
   ```
   Check that every image/document in the database has its file:
   ```python
   # sudo docker exec -i vfllcms-web uv run manage.py shell
   from wagtail.images import get_image_model
   from wagtail.documents import get_document_model
   for M in (get_image_model(), get_document_model()):
       print(M.__name__, M.objects.count(), sum(not o.file.storage.exists(o.file.name) for o in M.objects.all()))
   ```
4. Step 7.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| git: `Permission denied (publickey)` | Deploy key missing on GitHub or not at `/root/.ssh/vfllcms_deploy_key` → step 4. |
| web restarts, `JSONDecodeError` at `GOOGLE_CREDENTIALS` | `vault_vfllcms_google_credentials` isn't valid JSON (on 2026-11-07 it was truncated) → re-encrypt the full service account JSON. |
| `password authentication failed for user "vfllcms"` | The role password in Postgres differs from `POSTGRES_PASSWORD` (seen once, with a password starting with `%`). Fix: `sudo docker exec vfllcms-db sh -c 'psql -U vfllcms -d postgres -v pw="$POSTGRES_PASSWORD" -c "ALTER ROLE vfllcms PASSWORD :'"'"'pw'"'"'"'`, then the web container recovers by itself. Test over the container IP, not 127.0.0.1 (trusted without password). |
| 502 Bad Gateway | web is still starting (migrations + collectstatic) or crashed → `sudo docker compose logs web` in `/opt/docker/<name>`. |
| Images missing, pages fine | media not restored (step 6) or owned by root → `chown -R 1000:1000`. |
| No new events on vfll.de | `journalctl -t vfllcms-cron`; the eventmanager API must answer (https://veranstaltungskalender.vfll.de). |
