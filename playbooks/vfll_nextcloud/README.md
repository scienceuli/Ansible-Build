# VFLL Nextcloud on hertz

`https://oonc.vfll.de` - Nextcloud **35** with OnlyOffice, as containers on
hertz (`hertz.science-and-more.com`, Ubuntu 22.04, netcup). Migrated from a
native Nextcloud 26 on 2026-10-16 - history, test results and open
follow-ups: [MIGRATION_PLAN.md](MIGRATION_PLAN.md).

## Stack

All containers on the docker network `science-and-more.com`:

| Container | Image | Data | Role |
|---|---|---|---|
| `nginx01` + `certbot01` | `nginx:1.31.3-alpine`, `certbot/certbot` | `/usr/share/nginx01`, `/usr/share/certbot01` | `nginx`, `certbot` - only container with published ports (80/443) |
| `nextcloud01` | `nextcloud:35-apache` | volume `nextcloud01` → `/var/www/html` (code, `config/`, `custom_apps/`), **bind mount `/data` → `/data`** (user files, 48 GB+) | `nextcloud_docker` |
| `mariadb01` | `mariadb:10.11` | volume `mariadb01` | `mariadb` |
| `redis01` | `redis:7-alpine` | volume `redis01` | `redis` |
| `doc01` | `onlyoffice/documentserver:9.4.0` | none (documents live in Nextcloud) | `onlyoffice_documentserver` |

| URL | Goes to |
|---|---|
| `https://oonc.vfll.de` | `nextcloud01:80` (10 GB uploads, 3600 s timeouts; `/.well-known/cal\|carddav` answered by nginx) |
| `https://office.vfll.de` | `doc01:80` (websockets) - TODO: move to `https://oonc.vfll.de/onlyoffice/` |

Nextcloud ↔ OnlyOffice talk inside the docker network (`http://doc01/`,
`http://nextcloud01/`); only the browser uses the public URLs. The JWT secret
is the one from the old document server (env `JWT_SECRET` of `doc01`, also in
the onlyoffice app config).

Cron (root, on hertz):

| When | Job |
|---|---|
| every 5 min | `docker exec -u www-data nextcloud01 php -f /var/www/html/cron.php` |
| 01:31 | Nextcloud backup (see below) |
| 23:24 | restic `forget --prune` |
| Sun 00:55 | `docker-certbot-renew && docker restart nginx01` |

## Configuration

| File | What |
|---|---|
| `vars/prod.yml` | stack definition for `migrate.yml`: names, network, `/data`, public URLs, trusted domains |
| `vars/test.yml` | isolated test stack (`*-test`, network `nc-test`, copy of `/data`, mail off, ports on 127.0.0.1) |
| `inventories/host_vars/hertz/vars.yml` | `nginx_proxies`, certbot, `restic_backup_set` |
| `inventories/host_vars/hertz/vault.yml` | `vault_vfll_mariadb_root_password`, `vault_vfll_mariadb_password`, `vault_vfll_redis_password` |
| `inventories/group_vars/setup/vars.yml` | `docker_network_name`, `nginx_image`, `certbot_image`, restic repo/credentials |

Nextcloud's own settings live in `config.php` in the `nextcloud01` volume
(`/var/lib/docker/volumes/nextcloud01/_data/config/`) plus
`tweaks.config.php` (VFLL tweaks: previews, trashbin `auto, 7`, share folder
`/Freigaben`, phone region `DE`, …). Change them with `occ config:system:set`
(see below), not by re-running the migration.

## Ansible commands

From the repo root (`~/Devel/Ansible-Build`), so `ansible.cfg` and
`.vault-pass` are found.

**Update Nextcloud** (minor version or the next major - never skip a major):

```sh
# set vn_nextcloud_image in migrate.yml or pass it:
uv run ansible-playbook -i inventories playbooks/vfll_nextcloud/migrate.yml \
  -e @playbooks/vfll_nextcloud/vars/prod.yml -e vn_nextcloud_image=nextcloud:36-apache
```

The run pulls the image, recreates `nextcloud01`, waits for the image's
entrypoint (`occ upgrade`), runs pending upgrades of app-store apps, adds
missing DB indices, updates apps and re-enables everything that was enabled on
the old native instance. Steps that copy/import data only ran once (marker
files in `/srv/nc-prod`) and are skipped. Expect ~1-2 min downtime per run.
Back up first (see below) - there is no downgrade.

After a major upgrade, once: `-e vn_repair_expensive=true` (mimetype migrations).

**Update MariaDB / Redis / OnlyOffice images**: change `vn_mariadb_image`,
`vn_redis_image` or `vn_onlyoffice_image` in `migrate.yml` and run the same
command.

**Proxy / certificates** (after changing `nginx_proxies` in `host_vars/hertz`):

```sh
uv run ansible-playbook -i inventories playbooks/vfll_nextcloud/proxy.yml        # certbot + nginx
uv run ansible-playbook -i inventories playbooks/vfll_nextcloud/proxy.yml -t nginx
```

New domains get a certificate automatically (port 80 must reach hertz, DNS
must point to `45.9.61.229`).

**Backup job** (after changing `restic_backup_set` in `host_vars/hertz`):

```sh
uv run ansible-playbook -i inventories playbooks/setup.yml -t restic -l hertz
```

Always with `-l hertz` - `setup.yml` targets the whole `setup` group.

**Test stack** (try an update before production):

```sh
uv run ansible-playbook -i inventories playbooks/vfll_nextcloud/migrate.yml -e @playbooks/vfll_nextcloud/vars/test.yml
uv run ansible-playbook -i inventories playbooks/vfll_nextcloud/migrate.yml -e @playbooks/vfll_nextcloud/vars/test.yml -e vn_nextcloud_image=nextcloud:36-apache
ssh -L 8090:127.0.0.1:8090 -L 8091:127.0.0.1:8091 scienceuli@hertz.science-and-more.com   # → http://localhost:8090
uv run ansible-playbook -i inventories playbooks/vfll_nextcloud/teardown_test.yml -e @playbooks/vfll_nextcloud/vars/test.yml
```

The test stack copies the **current** live data (DB dump + rsync of `/data`,
~50 GB extra on hertz) and keeps the live instance running. Mail is disabled
in the copy. Remove it with `teardown_test.yml` when done.

Don't use `--check` with `migrate.yml`: the role waits on `docker exec`
results, which check mode skips.

## Backup

restic to `backup.science-and-more.com` (repo `hertz`, REST server), copied
nightly at 05:00 to the Hetzner Storage Box (see `inventories/host_vars/backup`).

`restic-nextcloud-backup -c nextcloud01 -m mariadb01 -D /data` (cron 01:31):

1. `occ maintenance:mode --on`
2. `mariadb-dump --single-transaction` in `mariadb01` → `/var/backup/nextcloud/nextcloud.sql`
3. `restic backup` of the dump, the `nextcloud01` volume and `/data`
4. `occ maintenance:mode --off` - also if a step fails

Usually 2-4 min maintenance at night (incremental). Run it by hand:

```sh
task connect-host hertz
sudo restic-nextcloud-backup -c nextcloud01 -m mariadb01 -D /data -o /var/backup/nextcloud -t nextcloud
sudo restic-main snapshots --tag nextcloud
```

Snapshot `a17afd00` (tag `pre-migration`) is the last state of the native
Nextcloud 26 before the switch.

### Restore

Restore into the **same Nextcloud version** the snapshot was taken with
(`version.php` in the volume) - check `occ status` vs. the snapshot date.

```sh
task connect-host hertz
sudo restic-main snapshots --tag nextcloud
sudo restic-main restore <snapshot> --target /var/tmp/restore     # ~50 GB, check df first
R=/var/tmp/restore

docker exec -u www-data nextcloud01 php occ maintenance:mode --on

# database
docker exec mariadb01 sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "DROP DATABASE nextcloud; CREATE DATABASE nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci; GRANT ALL ON nextcloud.* TO \"nextcloud\"@\"%\";"'
docker exec -i mariadb01 sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" nextcloud' < $R/var/backup/nextcloud/nextcloud.sql

# files - user data and the volume (config.php, custom_apps)
sudo rsync -a --delete $R/data/ /data/
sudo rsync -a --delete $R/var/lib/docker/volumes/nextcloud01/_data/ /var/lib/docker/volumes/nextcloud01/_data/

docker restart nextcloud01
docker exec -u www-data nextcloud01 php occ maintenance:mode --off   # restored config.php has maintenance on
docker exec -u www-data nextcloud01 php occ maintenance:data-fingerprint
sudo rm -rf $R
```

Single files or one user: restore only that path, e.g.
`sudo restic-main restore <snapshot> --target /var/tmp/restore --include /data/<user>/files/<path>`,
copy it into `/data/<user>/files/`, then
`docker exec -u www-data nextcloud01 php occ files:scan <user>`.
Deleted files of the last 7 days are also in the user's trash bin.

## Useful commands

```sh
task connect-host hertz
occ() { docker exec -u www-data nextcloud01 php occ "$@"; }
occ status
occ app:list
occ setupchecks
occ config:system:get <key>         # e.g. trusted_domains, redis, maintenance_window_start
occ config:system:set <key> --value=<value>
occ user:list
occ onlyoffice:documentserver --check
docker logs -f nextcloud01           # entrypoint / apache
docker exec nextcloud01 tail -f /data/nextcloud.log
docker logs -f nginx01
```

### Logs - "document opens slowly / not at all"

```sh
occ log:tail 30                      # Nextcloud log, readable (same as Administration → Logging)
docker logs --since 24h nginx01 | grep '" 5[0-9][0-9] \|" 499 '   # server errors, client gave up
# per user/IP: an editor open is config/<fileId> (Nextcloud) → Editor.bin
# (document content) → /doc/<key>/c/ 101 (websocket, logged when closed).
# config without Editor.bin = editor never connected (often browser/antivirus/proxy)
docker logs --since 24h nginx01 | grep -E 'onlyoffice/api/v1/config/|/cache/files/|/doc/.*/c/' | grep <ip>
docker exec doc01 tail -f /var/log/onlyoffice/documentserver/docservice/out.log
docker exec doc01 tail -f /var/log/onlyoffice/documentserver/converter/out.log
```

## Pitfalls (found while migrating)

- App-store apps must be in `custom_apps/`: the image's entrypoint replaces
  `apps/` on every upgrade. `apps_paths` is set in `config.php`.
- `tweaks.config.php` is read after `config.php` and overrides it - keys the
  stack manages (redis, memcache, overwriteprotocol, logfile) were removed
  from it; don't add them back there. Deprecated keys (`blacklisted_files` →
  `forbidden_filenames`) are renamed by `migrate.yml` on every run.
- After an upgrade the app-store apps get newer versions that need another
  `occ upgrade`; the role does that (`Run pending occ upgrades`).
- The old services are still installed on the host but stopped/disabled
  (nginx, old `ONLYOFFICEDOCKER`) or idle (php8.1-fpm, MariaDB, Redis, native
  Nextcloud in maintenance) - see MIGRATION_PLAN.md for their removal. Don't
  start the host nginx: it would take ports 80/443 from `nginx01`.
- Old, unused docker volumes from earlier setups: `compose_*`,
  `docker-onlyoffice-nextcloud_*` - remove with the old services.
