# How to deploy: VFLL Eventmanager on bohr

From a freshly installed bohr (Netcup, Debian 13) to
`https://veranstaltungskalender.vfll.de` and the staging instance.
Background on the stack: [README.md](README.md).

Three inventory hosts point at the same server:

| Inventory host | What it's for | Vars |
|---|---|---|
| `bohr` | the server: users, packages, firewall, Docker, nginx + certbot containers, restic | `inventories/host_vars/bohr/`, `group_vars/setup`, `group_vars/debian13.yml` |
| `bohr_eventmanager` | production stack in `/opt/docker/eventmanager` | `inventories/host_vars/bohr_eventmanager/` |
| `bohr_eventmanager_staging` | staging stack in `/opt/docker/eventmanager-staging` | `inventories/host_vars/bohr_eventmanager_staging/` |

The VFLL Wagtail CMS runs on the same server
([../vfllcms/HOW_TO_DEPLOY.md](../vfllcms/HOW_TO_DEPLOY.md)). Steps 1-3 are
the same for both apps: do them once.

Run every command **from the repo root** (`~/Devel/Ansible-Build`), so
`ansible.cfg` and `.vault-pass` are found, and always with `-l` as shown:
`setup.yml` and `bootstrap.yml` target the whole `setup` group, which also
contains `localhost`.

## 0. Prerequisites

- DNS at all-inkl (KAS): `veranstaltungskalender.vfll.de` and
  `staging.veranstaltungskalender.vfll.de` → `94.16.123.175` (bohr). Check:
  `dig +short veranstaltungskalender.vfll.de`.
- In the Netcup server control panel (SCP), your SSH key is put on `root`
  when you reinstall the image.
- Secrets in `inventories/host_vars/bohr_eventmanager*/vault.yml`:
  `vault_eventmanager_secret_key`, `vault_eventmanager_encrypt_key`,
  `vault_eventmanager_db_password`, SMTP, member admin, Mailgun (production).
  Plain values only - no quotes around them, no `$` (README, "Configuration").
- Ansible collections: `uv run ansible-galaxy collection install -r playbooks/eventmanager/requirements.yml`

## 1. Trust the new SSH host key

A reinstall changes it:

```sh
ssh-keygen -R bohr.science-and-more.com; ssh-keygen -R 94.16.123.175
ssh root@bohr.science-and-more.com true      # accept the new key
```

Mind the domain: `bohr.science-and-more.com`, **not** `.de` (that's a
different server, which asks for a password).

## 2. Bootstrap: create your user (as root)

Installs the `debian13` packages (incl. `sudo`, `zsh`, `git`, `acl`) and runs
`iam` (users `scienceuli` and `bot`, groups, passwordless sudo for `wheel`,
root password):

```sh
uv run ansible-playbook -i inventories playbooks/bootstrap.yml -l bohr
ssh scienceuli@bohr.science-and-more.com 'sudo -n whoami'   # → root
```

Check that before continuing - the next step disables root login over SSH.

## 3. Server setup (as scienceuli), without restic

Timezone, DNS resolvers, locale, cron helpers, maintenance jobs, Docker +
the `science-and-more.com` network, `ufw` (22/80/443 only), SSH hardening,
`iam` again:

```sh
uv run ansible-playbook -i inventories playbooks/setup.yml -l bohr --skip-tags restic
```

Skip restic on a fresh server: the restic role checks that the backed-up
paths (`/opt/docker/eventmanager/data`, ...) exist, and they only appear
with the app deploy - with restic, the setup stops there and the roles after
it (Docker, ufw, iam) don't run. restic follows in step 7.

## 4. Deploy both instances (without nginx)

```sh
uv run ansible-playbook -i inventories playbooks/eventmanager/playbook.yml \
  -l bohr,bohr_eventmanager,bohr_eventmanager_staging --skip-tags htpasswd,certbot,nginx
```

Clones the repo, builds the image (the first build takes a few minutes),
starts `db`, `mjml`, `web`. nginx comes once all apps on bohr are deployed
(step 6): it bind-mounts the data dirs of all four instances.

To fill the databases from a dump, add `-e eventmanager_restore_dump=...`
(see "Restore a database dump"). On a fresh database: README.md, "First run
on a fresh database".

## 5. Media

Uploads aren't in the dump. See "Migration from the native bohr" for
the move from the old layout, or restore `data/` from restic.

## 6. Reverse proxy + TLS (all apps on bohr)

Once the eventmanager **and** vfllcms instances are deployed:

```sh
uv run ansible-playbook -i inventories playbooks/eventmanager/playbook.yml -l bohr -t htpasswd,certbot,nginx
```

certbot issues the Let's Encrypt certificates for all `nginx_proxies` of bohr
(port 80 reachable, DNS correct), then nginx starts with TLS. Check:

```sh
curl -I https://veranstaltungskalender.vfll.de                          # 200
curl -I https://staging.veranstaltungskalender.vfll.de                  # 401 (basic auth)
curl -I http://veranstaltungskalender.vfll.de                           # 301 → https
curl -I https://veranstaltungskalender.vfll.de/media/invoices/x.pdf     # 404
ssh scienceuli@bohr.science-and-more.com docker ps
```

## 7. Backup

```sh
uv run ansible-playbook -i inventories playbooks/setup.yml -l bohr -t restic
```

Initializes the repo `bohr` on backup.science-and-more.com (on the first run
the "Check if repo is initialized" error is expected and ignored) and
registers the cron jobs (production only, see README).

## Later deployments

- **New app version:** push to `main` of the eventmanager repo, then
  `uv run ansible-playbook -i inventories playbooks/eventmanager/playbook.yml -l bohr,bohr_eventmanager`
  (or `bohr_eventmanager_staging` - test there first).
- **Only proxy config changed** (`host_vars/bohr/vars.yml`): step 6 with `-t nginx`.
- **Server baseline changed:** `setup.yml -l bohr` (now with restic).

## Restore a database dump

Replaces the database with a `pg_dump -Fc` file from your Mac (role
`compose_pg_restore`: stops the app services, drops/recreates the db,
restores in one transaction, starts the app, which migrates):

```sh
uv run ansible-playbook -i inventories playbooks/eventmanager/playbook.yml \
  -l bohr,bohr_eventmanager_staging --skip-tags htpasswd,certbot,nginx \
  -e eventmanager_restore_dump=$HOME/path/to/eventmanager.pgdump
```

Refreshing staging from production: dump production on bohr first
(`sudo docker exec eventmanager-db pg_dump -Fc -U eventmanager eventmanager > ...`),
copy it to your Mac, then run the above.

**Production with SMTP:** check the mail queue of the dump before (README,
"Mail queue") - with `eventmanager_mailqueue_autosend: true` every unsent
mail goes out right after the restore. On 2026-11-07 production was
restored with
`-e eventmanager_email_backend=django.core.mail.backends.filebased.EmailBackend`
first, the 52 old unsent mails set to `sent`, and only then deployed with
SMTP.

## Migration from the native bohr (2026-11-07)

How production moved from the hand-installed bohr (Ubuntu 20.04) to the
reinstalled one, for reference:

1. **Freeze:** `sudo supervisorctl stop vfllcms eventmanager_dev` and the
   crontab lines commented out on the old bohr.
2. **Final backup to the Mac:**
   `playbooks/bohr_migration/backup_bohr_native.sh <dir>` - pg_dumps of
   `vfllcms` and `vfllfobi_dev` (= eventmanager), `/home/scienceuli` without
   venvs (code, media, `.env`, settings), nginx/supervisor config. It refuses
   to run while gunicorn is up. Result:
   `~/hetzner_nc/Backups/vfll_backups/final/`.
3. Reinstall, steps 1-4 with `-e eventmanager_restore_dump=.../final/eventmanager.pgdump`.
4. **Media:** the native app kept the private files in `media/` (no
   `PRIVATE_STORAGE_ROOT`). The database stores them relative to the storage
   root (`invoices/...`), so they move one to one into `data/private/`:
   ```sh
   tar -xzf final/home.tar.gz scienceuli/eventmanager_dev/media scienceuli/eventmanager_dev/sent_emails
   B=scienceuli/eventmanager_dev; H=scienceuli@bohr.science-and-more.com; D=/opt/docker/eventmanager/data
   rsync -a --rsync-path="sudo rsync" --exclude=/invoices --exclude=/confirmations \
     --exclude=/uploaded_private_documents --exclude=/stornos $B/media/ $H:$D/media/
   for p in invoices confirmations uploaded_private_documents stornos; do
     [ -d "$B/media/$p" ] && rsync -a --rsync-path="sudo rsync" "$B/media/$p" "$H:$D/private/"
   done
   rsync -a --rsync-path="sudo rsync" $B/sent_emails/ $H:$D/sent_emails/
   ssh $H "sudo chown -R 1000:1000 $D/media $D/private $D/sent_emails"
   ```
   Same for staging (`/opt/docker/eventmanager-staging/data`, without
   `sent_emails`). Check that every file referenced in the database exists:
   ```python
   # sudo docker exec -i eventmanager python manage.py shell
   from invoices.models import Invoice
   qs = Invoice.objects.exclude(pdf="").exclude(pdf__isnull=True)
   print(qs.count(), sum(not i.pdf.storage.exists(i.pdf.name) for i in qs))   # missing: 0
   ```
5. Steps 6 and 7.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Host key verification failed` | The server was reinstalled → step 1. |
| `ssh root@bohr...` asks for a password | Typo `.de` instead of `.com`, or the key wasn't put on root in the SCP. |
| `sudo: a password is required` | Your user isn't in `wheel` yet → step 2 didn't finish; re-run it. |
| `Permission denied (publickey)` as root after step 3 | Expected: step 3 disables root login. Use `scienceuli`. |
| setup.yml: restic `Verify file path exists` fails | Fresh server, apps not deployed yet → `--skip-tags restic` (step 3). |
| compose: `unexpected character "'" in variable name` | A vault value is wrapped in quotes → re-encrypt it without (README, "Configuration"). |
| `password authentication failed for user "eventmanager"` | The role password in Postgres differs from `POSTGRES_PASSWORD` (only set on the first start against an empty `db-data`). Fix: `sudo docker exec <name>-db sh -c 'psql -U eventmanager -d postgres -v pw="$POSTGRES_PASSWORD" -c "ALTER ROLE eventmanager PASSWORD :'"'"'pw'"'"'"'`. Test over the container IP, not 127.0.0.1 (trusted without password). |
| certbot: `Some challenges have failed` | DNS doesn't point to bohr yet, or port 80 is blocked (`ufw status`). |
| 502 Bad Gateway | `web` is still starting (migrations + collectstatic) or crashed → `sudo docker compose logs web` in `/opt/docker/<name>`. |
| `/static/` gives 404 | collectstatic hasn't run yet (web logs); nginx mounts `/opt/docker/<name>/data/static` read-only. |
| Invoice download fails | File missing in `data/private/invoices/` (step 5), or owned by root → `chown -R 1000:1000`. |
