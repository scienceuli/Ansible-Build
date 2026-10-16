# Migration plan: VFLL Nextcloud + OnlyOffice on hertz → containers

## Done: switched 2026-10-16, 22:20-22:55

Live on **Nextcloud 35.0.1** in containers (`nextcloud01`, `mariadb01`,
`redis01`, `doc01`, `nginx01`/`certbot01`), 99 users, all apps carried over
(only `files_rightclick` gone - part of core). Run log:

| Time | Step |
|---|---|
| 22:20 | maintenance on; old cron jobs commented out (`#MIGRATED 2026-10-16#`, originals in `/root/migration-2026-10-16/`) |
| 22:23 | final native backup: restic snapshot `a17afd00` (tag `pre-migration`) |
| 22:26-22:29 | `migrate.yml` + `vars/prod.yml` → container stack on 26.0.13 |
| 22:30-22:32 | host nginx stopped + disabled, old `ONLYOFFICEDOCKER` stopped (restart=no), `proxy.yml`: new certificates for `oonc.vfll.de` and `office.vfll.de` |
| 22:34-22:48 | 27 → 35, ~1.5 min each, then mimetype repair |
| 22:49 | backup switched to container mode, first run: snapshot `6e8ecf5f` (3 min) |

Follow-ups:
- [ ] users: announcement "done" (Announcement Center)
- [ ] OnlyOffice to `https://oonc.vfll.de/onlyoffice/`, then drop `office.vfll.de` (proxy entry + DNS)
- [x] secrets in `host_vars/hertz/vault.yml` (`vault_vfll_*`, 2026-10-16; `/srv/nc-prod/secrets.json` no longer read)
- [x] `127.0.0.1:8090` dropped - only nginx01 reaches nextcloud01
- [x] restore test of the container backup (snapshot `6e8ecf5f`: volume identical except maintenance flag, 171 tables, identical row counts)
- [ ] MariaDB tuning hints (Administration → System → Database)
- [ ] ~2 weeks without problems: remove native php8.1-fpm, MariaDB, Redis, nginx, certbot/acme.sh,
      `/var/www/nextcloud`, `ONLYOFFICEDOCKER` + `/app/onlyoffice`; old docker apt source → `docker` role

Rollback now only via restic (`a17afd00` = native 26.0.1 state).

**Originally planned window: Friday 2026-10-16, 20:00-22:00** (announced to
users via the Announcement Center app, installed 2026-10-12).

`office.vfll.de` and its certificates are dropped: only hertz's Nextcloud uses
the document server (checked in the nginx logs). OnlyOffice moves to
`https://oonc.vfll.de/onlyoffice/` - one domain, one certificate; delete the
`office.vfll.de` DNS record afterwards.

Security note: on 2026-10-10 `212.232.23.99` (rockhoster.net) probed the old
OnlyOffice with path-traversal requests on `/downloadas/` (attempts to write to
`/tmp`). None reached the document server (nginx answered 301/404), nothing
found in the container - but the 2023 image is a target; another reason to
switch.

Status (2026-10-12): **test run passed**, live instance unchanged. Backup in
place: restic repo `hertz` (restore-tested), nightly 01:31.

## Test run results

`migrate.yml` with `vars/test.yml` (isolated `*-test` stack on hertz, copy of
`/data`, mail off), from scratch, then one major per run:

| Step | Result |
|---|---|
| 26 (copy, DB import, 26.0.1 → 26.0.13) | ok, 7 min; needed the extra `occ upgrade` (app-store app updates) - automated |
| 27 → 35 | ok, ~1 min each, ends on **35.0.1** |
| Apps | all natively enabled apps enabled again (calendar 6.6, contacts 8.9, groupfolders 23, excalidraw 4.0, onlyoffice 10.2); `files_rightclick` no longer exists (part of core) |
| OnlyOffice 9.4 | connected with the existing JWT secret |
| Log | only transient errors during the version steps (apps between versions, removed Right click app) |

Found and fixed during the test runs:
- app-store apps in `apps/` were deleted by the image's entrypoint → moved to
  `custom_apps`, `apps_paths` set in `config.php` (the image only adds it on
  fresh installs)
- `tweaks.config.php` overrode `config.php` (old redis socket, logfile,
  overwriteprotocol) → container-managed keys are removed from all extra
  `*.config.php`; VFLL's own tweaks (previews, trashbin, `/Freigaben`, …) stay
- waiting for the upgrade raced with the image's entrypoint → the role waits
  for PID 1 = apache2, then runs pending `occ upgrade`s
- maintenance window 01:00 UTC, mimetype migration after the last step

Open after the switch: MariaDB tuning hints from Nextcloud's database
advisor (Administration → System → Database) - add to `mariadb_command`.

## Today (as found)

| | |
|---|---|
| Host | hertz (`hertz.science-and-more.com`, 45.9.61.229), Ubuntu 22.04, 4 CPU, 15 GB RAM, 226 GB free |
| Nextcloud | **26.0.1** (EOL), native in `/var/www/nextcloud` (2.1 GB incl. apps), nginx + PHP 8.1-FPM, cron as `www-data` every 5 min |
| Data | `/data`, 48 GB, 9.5k files, owner `www-data` (uid 33 - same uid as in the `nextcloud` image) |
| Database | MariaDB **10.8** native, DB `nextcloud`, user `ncdbuser`, 49 MB |
| Cache/locking | APCu (local), Redis 6.0 via unix socket (`/var/run/redis/redis-server.sock`, dbindex 1) |
| Apps (non-default) | calendar, contacts, groupfolders, integration_excalidraw, onlyoffice |
| Mail | SMTP settings in `config.php` (`mail_smtp*`) |
| OnlyOffice | container `ONLYOFFICEDOCKER` (`onlyoffice/documentserver`, image from 2023), `127.0.0.1:8443`, bind mounts under `/app/onlyoffice/DocumentServer/`; JWT secret via env `JWT_SECRET`, identical to the Nextcloud app's `jwt_secret` |
| nginx (`/etc/nginx/conf.d/`) | `oonc.vfll.de` → PHP-FPM (`client_max_body_size 10G`, `fastcgi_read_timeout 3600`), `office.vfll.de` → `https://127.0.0.1:8443` (`proxy_read_timeout 3600s`) |
| Certificates | certbot for `oonc.vfll.de`; `/root/renewal.sh` (weekly) for `office.vfll.de` (`ecc-certs`/`rsa-certs`) |
| Other cron | `/usr/local/bin/nginx-watchdog.sh` every 5 min |

## Target

Same server, container stack like faraday/backup - everything on the docker
network `science-and-more.com`:

| Container | Role | Notes |
|---|---|---|
| `nginx01` + `certbot01` | `nginx`, `certbot` | ports 80/443; `oonc.vfll.de` → `nextcloud01:80`, `office.vfll.de` → `doc01:80` |
| `nextcloud01` | `nextcloud_docker` (new, from mint-system's `nextcloud` role) | `nextcloud:<N>-apache`; `/var/www/html` in a docker volume, **`/data` bind-mounted at `/data`** (datadirectory stays `/data`, no copy of the 48 GB) |
| `mariadb01` | `mariadb` | `mariadb:10.11` (LTS, supported by current Nextcloud) |
| `redis01` | `redis` | with password |
| `doc01` | `onlyoffice_documentserver` | current image, **same JWT secret** |

Cron: `docker exec -u www-data nextcloud01 php -f cron.php` every 5 min (role).
Backups: restic, adapted to the container setup (see phase 4).

## Upgrade path

Nextcloud only upgrades **one major version at a time**: 26 → 27 → 28 → …
→ current. The `nextcloud` image runs `occ upgrade` itself when started with
the next major tag. So: start the container with `26-apache` (latest 26.0.x),
then switch the image tag major by major. After each step: `occ status`,
`occ app:update --all`, check the log, quick test in the browser. Apps that
aren't compatible with a step get disabled by the upgrade - check
`occ app:list` afterwards (groupfolders and integration_excalidraw are the
likely candidates).

## Phases

### Phase 0 - Prerequisites (no downtime)

1. Inventory: `group_vars/ubuntu22.yml` (`docker_packages`, `docker_apt_repo`
   for jammy, `group_packages` incl. zsh/git/acl/sudo) - so the shared roles
   work on hertz. Run only selected roles (`-t docker,docker_network`), **not**
   the full `setup.yml`/`iam` until the packages are there (zsh lock-out, see
   backup).
2. Role `nextcloud_docker`: mint-system's `nextcloud` role (the local
   `nextcloud` role is the compose one for dirac), extended with
   - `nextcloud_extra_volumes` (`/data:/data`)
   - no `NEXTCLOUD_ADMIN_*`/`SMTP_*` env when an existing install is migrated
     (they only matter for a fresh install and could trigger one)
   - `trusted_proxies` from the real network subnet instead of the hard-coded
     `172.18.0.0/30`
3. Vault (`host_vars/hertz/vault.yml`): `vault_mariadb_root_password`,
   `vault_mariadb_password` (new `nextcloud` DB user),
   `vault_redis_password`, `vault_onlyoffice_documentserver_jwt_secret`
   (**the current value**, read from the old container).
4. `host_vars/hertz/vars.yml`: images, hostnames, `nginx_proxies` for both
   domains (`client_max_body_size 10G`, timeouts 3600, websocket headers for
   OnlyOffice).
5. Test the whole stack first on a throwaway copy (restore of snapshot
   `ce8b4981` into a test VM or a second docker stack on hertz with another
   network and no published ports) - including the upgrade steps, so the
   real run has no surprises.

### Phase 1 - Prepare on hertz (no downtime)

Docker network, `mariadb01`, `redis01`, `doc01` start alongside the old
stack (no port conflicts: only nginx needs 80/443). Pull all Nextcloud images
for the upgrade path in advance.

### Phase 2 - Cutover (downtime, announce to VFLL users)

1. `occ maintenance:mode --on`, stop the old cron job.
2. Final backup (`restic-nextcloud-backup`, incremental, a few minutes).
3. Dump the DB → import into `mariadb01`.
4. Copy `/var/www/nextcloud` (code + `config/` + apps) into the
   `nextcloud01` volume - so the image's entrypoint sees an existing 26.0.1
   install and upgrades it to the image's 26.0.x instead of installing anew.
5. Adapt `config.php`: `dbhost` → `mariadb01`, DB user/password, `redis` →
   `redis01` + password, `trusted_proxies`, `overwriteprotocol https`.
   Keep `instanceid`, `passwordsalt`, `secret`, `datadirectory` unchanged.
6. Stop host nginx, PHP-FPM, old OnlyOffice container; start `nextcloud01`
   (26) → `occ status`.
7. Start `certbot01`/`nginx01` (new certificates via port 80 for both domains).
8. OnlyOffice app: `DocumentServerUrl https://office.vfll.de/`, internal URL
   `http://doc01/`, `StorageUrl http://nextcloud01/` (traffic stays inside
   docker). Test: open and save a document.
9. Maintenance off, smoke test (login, files, calendar, sharing, OnlyOffice).

Estimated: 30-60 min (mostly step 2-4 and the tests).

### Phase 3 - Upgrades (separate evenings or same window)

26 → 27 → … → current, one major per step as described above, each step
~5-15 min downtime. Backup before each step (`restic-main backup` of the DB
dump is enough, `/data` barely changes).

### Phase 4 - Backups and cleanup

1. Backup type for the container setup: maintenance via `docker exec`,
   `mysqldump` via `docker exec mariadb01`, restic of dump + `/data` + the
   `nextcloud01` volume (config, apps). Replaces the native `nextcloud` type
   on hertz; restore test again.
2. After ~2 weeks without problems: disable/remove native nginx, PHP-FPM,
   MariaDB, Redis, certbot timer + `/root/renewal.sh`, `nginx-watchdog.sh`,
   old `ONLYOFFICEDOCKER` and `/app/onlyoffice`. Keep the final native dump.
3. Later, separately: Ubuntu 22.04 is supported until 04/2027 - plan the host
   OS upgrade (or a move to Debian 13 like the other servers).

## Rollback

- **During phase 2:** stop the containers, start host nginx/PHP-FPM, maintenance
  off. The native MariaDB and `/var/www/nextcloud` are untouched (the
  containers work on copies); `/data` is shared but unchanged by 26 → 26.0.x.
- **After the first major upgrade:** no way back to the native 26 with the
  same `/data` - restore from restic (DB dump + `/data` + config of the
  snapshot before the step).

## Open questions

- Target version: latest stable major at migration time (check the tags on
  hub.docker.com/_/nextcloud), and whether every app has a compatible release.
- Downtime window for phase 2 - VFLL users need to know beforehand.
- OnlyOffice custom fonts: the old container has a fonts volume
  (`/usr/share/fonts/truetype/custom`) - check whether anything is in it.
- `office.vfll.de` certificates: why a separate `renewal.sh` with ECC+RSA - the
  new certbot container issues one certificate per domain, which should be enough.
