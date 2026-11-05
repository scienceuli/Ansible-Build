# How to deploy: faraday (Debian 13 server) + VFLL Eventmanager

From a freshly installed Hetzner server to `https://faraday.science-and-more.com`.
Background on the stack: [README.md](README.md).

Two inventory hosts point at the same server:

| Inventory host | What it's for | Vars |
|---|---|---|
| `faraday` | the server: users, packages, firewall, Docker, nginx + certbot containers | `inventories/host_vars/faraday/vars.yml`, `group_vars/setup`, `group_vars/debian13.yml` |
| `faraday_eventmanager` | the app: compose stack in `/opt/docker/eventmanager` | `inventories/host_vars/faraday_eventmanager/` |

Run every command **from the repo root** (`~/Devel/Ansible-Build`), so
`ansible.cfg` and `.vault-pass` are found, and always with `-l faraday`
where shown: `setup.yml` and `bootstrap.yml` target the whole `setup`
group, which also contains `localhost`.

## 0. Prerequisites

- `faraday.science-and-more.com` resolves to the server
  (`dig +short faraday.science-and-more.com` → `37.27.144.19`).
- Hetzner put your SSH key on `root` (chosen when creating the server).
- Secrets in `inventories/host_vars/faraday_eventmanager/vault.yml`:
  `vault_eventmanager_secret_key`, `vault_eventmanager_encrypt_key`,
  `vault_eventmanager_db_password`. Keep `$` out of them (compose interpolates it).
- Ansible collections: `uv run ansible-galaxy collection install -r playbooks/eventmanager/requirements.yml`
- Optional: add `ansible_user: scienceuli` to `faraday_eventmanager` in
  `inventories/hosts.yml` - without it Ansible connects with your local
  username (which happens to be the same).

## 1. Trust the server's SSH host key

```sh
ssh-keyscan -t ed25519 faraday.science-and-more.com 2>/dev/null | ssh-keygen -lf -
```

Compare the fingerprint with the one Hetzner shows for the server (Cloud
Console → server → *Rescue/Console*, or the install mail). Only if it
matches, log in once as root and accept it:

```sh
ssh root@faraday.science-and-more.com true
```

### No SSH key on root (`Permission denied (publickey,password)`)

If no key was selected when the server was created, use a root password once:

1. Cloud Console → server → **Rescue** → **Reset root password**; copy it
   (shown only once).
2. Verify the host key: open the web console (`>_`), log in as `root`, run
   `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` and compare it with
   what `ssh-keyscan` showed above.
3. From your Mac: `ssh-copy-id -i ~/.ssh/id_rsa.pub root@faraday.science-and-more.com`
   (answer `yes` to the host key, enter the root password).
4. `ssh root@faraday.science-and-more.com true` must now work without a password.

No need to keep that password: step 2 replaces it (`vault_iam_root_password`)
and step 3 disables root and password logins over SSH.

## 2. Bootstrap: create your user (as root)

Installs the `debian13` packages (incl. `sudo`, `zsh`, `git`, `acl`) and runs
`iam` (users `scienceuli` and `bot`, groups, passwordless sudo for `wheel`,
root password):

```sh
task play -i inventories playbooks/bootstrap.yml -l faraday
```

Check that your own user works before continuing - the next step disables
root login over SSH:

```sh
ssh scienceuli@faraday.science-and-more.com 'sudo -n whoami'   # → root
```

## 3. Server setup (as scienceuli)

Timezone, DNS resolvers, locale, cron helpers, maintenance jobs, Docker +
the `science-and-more.com` network, `ufw` (22/80/443 only), SSH hardening,
`iam` again, and the restic backup client (repo `faraday` on
backup.science-and-more.com):

```sh
task play -i inventories playbooks/setup.yml -l faraday
```

(`--check` doesn't work on a fresh server - apt's check mode needs
`python3-apt`, which only a real run installs.)

## 4. Deploy the Eventmanager

```sh
task play -i inventories playbooks/eventmanager/playbook.yml
```

Three plays, in this order:

1. `faraday`: Docker + network (no-op after step 3).
2. `faraday_eventmanager`: clones the repo, builds the image, starts
   `db`, `mjml`, `web`, `mailqueue`. The first build takes a few minutes.
3. `faraday`: certbot issues the Let's Encrypt certificate (port 80 must be
   reachable and DNS correct), then nginx starts with TLS and proxies to
   `eventmanager-web:8000`.

## 5. Check it

```sh
curl -I https://faraday.science-and-more.com          # 200/302 from Django
curl -I http://faraday.science-and-more.com           # 301 → https
task connect-host faraday
  docker ps                                            # nginx01, eventmanager-web/-db/-mjml/-mailqueue
  cd /opt/docker/eventmanager && sudo docker compose logs -f web
```

## 6. First run on a fresh database

```sh
ssh -t scienceuli@faraday.science-and-more.com \
  "sudo docker exec -it eventmanager-web python manage.py createsuperuser"
```

**Required:** the user groups. Templates check membership with the
`has_group` filter, and a missing group gives an Internal Server Error on `/`
(`Group matching query does not exist`):

```sh
ssh -t scienceuli@faraday.science-and-more.com \
  "sudo docker exec eventmanager-web python manage.py loaddata data/initial_groups.json data/initial_email_templates.json"
# "newsletter" is used in templates but missing from initial_groups.json:
ssh -t scienceuli@faraday.science-and-more.com \
  "sudo docker exec eventmanager-web python manage.py shell -c \"from django.contrib.auth.models import Group; Group.objects.get_or_create(name='newsletter')\""
```

Then set the `Site` domain - see
[README.md](README.md#first-run-on-a-fresh-database).

## Later deployments

- **New app version:** push to `main` of the eventmanager repo, then re-run step 4.
- **Only proxy config changed** (`host_vars/faraday/vars.yml`):
  `uv run ansible-playbook -i inventories playbooks/eventmanager/playbook.yml -t nginx`
- **Server baseline changed:** re-run step 3.

## Restore a production dump

Replaces the database with a `pg_dump -Fc` file from your Mac (role
`compose_pg_restore`: stops web + mailqueue, drops/recreates the db, restores
in one transaction, starts the app, which migrates):

```sh
uv run ansible-playbook -i inventories playbooks/eventmanager/playbook.yml \
  -l faraday,faraday_eventmanager -e eventmanager_restore_dump=$HOME/path/to/eventmanager.pgdump
```

Files are separate. Private uploads go to `data/private`, not `data/media` -
nginx serves `media/` publicly (bohr kept everything in `media/`):

```sh
B=~/Devel/vfll_backups/migration_2026-11/eventmanager_media   # copy of bohr's media/
H=scienceuli@faraday.science-and-more.com; D=/opt/docker/eventmanager/data
rsync -a --rsync-path="sudo rsync" --exclude=/invoices/ --exclude=/confirmations/ \
  --exclude=/uploaded_private_documents/ --exclude=/stornos/ $B/ $H:$D/media/
for p in invoices confirmations uploaded_private_documents stornos; do
  [ -d "$B/$p" ] && rsync -a --rsync-path="sudo rsync" "$B/$p/" "$H:$D/private/$p/"
done
ssh $H "sudo chown -R 1000:1000 $D/media $D/private"
```

## Cutover from bohr (veranstaltungskalender.vfll.de)

faraday already runs with production's `SECRET_KEY`/`ENCRYPT_KEY`, SMTP and
member-admin settings (`host_vars/faraday_eventmanager`), but on its own
name, with mails to files, without Mailgun and without the cron job. The
`CUTOVER` comments in `host_vars/faraday_eventmanager/vars.yml` and
`host_vars/faraday/vars.yml` mark what to switch. Expect ~30 min downtime.

1. **A day before:** lower the TTL of `veranstaltungskalender.vfll.de` at
   all-inkl (KAS) to 300 s.
2. **Freeze bohr:** set `MAINTENANCE_MODE = True` in
   `~/eventmanager_dev/eventmanager/local_settings.py`, restart gunicorn
   (`sudo systemctl restart gunicornemdev`), and comment out the
   `manage.py crontab run` and `backup_em.sh` lines in `crontab -e`.
3. **Fresh copy:** dump on bohr and fetch the media again (see
   "Restore a production dump"; rsync only transfers what changed):
   ```sh
   ssh scienceuli@bohr.science-and-more.com 'f=~/eventmanager_dev/eventmanager/.env; g(){ grep -m1 "^$1=" $f | cut -d= -f2-; }; PGPASSWORD="$(g DB_PASSWORD)" pg_dump -Fc -h "$(g DB_HOST)" -U "$(g DB_USER)" -d "$(g DB_NAME)"' > ~/Devel/vfll_backups/migration_2026-11/eventmanager_cutover.pgdump
   rsync -a scienceuli@bohr.science-and-more.com:eventmanager_dev/media/ ~/Devel/vfll_backups/migration_2026-11/eventmanager_media/
   ```
4. **Switch faraday** (`CUTOVER` in `host_vars/faraday_eventmanager/vars.yml`):
   `eventmanager_domain: veranstaltungskalender.vfll.de`,
   `eventmanager_domain_aliases: [faraday.science-and-more.com]`, SMTP
   backend, Mailgun from the vault, `eventmanager_cron_jobs` with
   `fetch_emails`. Then restore and deploy in one go:
   ```sh
   uv run ansible-playbook -i inventories playbooks/eventmanager/playbook.yml \
     -l faraday,faraday_eventmanager -e eventmanager_restore_dump=$HOME/Devel/vfll_backups/migration_2026-11/eventmanager_cutover.pgdump
   ```
   plus the media rsync from "Restore a production dump".
5. **DNS:** point the A record of `veranstaltungskalender.vfll.de` to
   `37.27.144.199`; wait until `dig +short veranstaltungskalender.vfll.de`
   shows it.
6. **TLS:** uncomment the `veranstaltungskalender.vfll.de` entry in
   `host_vars/faraday/vars.yml`, then
   `uv run ansible-playbook -i inventories playbooks/eventmanager/playbook.yml -l faraday -t certbot,nginx`.
7. **Check:** site, admin login, one invoice download (via the app), a test
   registration mail, `/media/invoices/...` must be 404.
   `journalctl -t eventmanager-cron` the next morning.
8. **bohr** keeps showing the maintenance page for clients with an old DNS
   answer; stop it (`sudo systemctl disable --now gunicornemdev`) once
   traffic is gone.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Host key verification failed` | Step 1 not done, or the server was reinstalled (new key: remove the old one with `ssh-keygen -R faraday.science-and-more.com`, then step 1). |
| `sudo: a password is required` | Your user isn't in `wheel` yet → step 2 didn't finish; re-run it. |
| `Permission denied (publickey)` as root after step 3 | Expected: step 3 disables root login. Use `scienceuli`. |
| `Unable to encrypt nor hash, passlib must be installed` | `uv sync` (passlib is in `pyproject.toml`). |
| certbot: `Some challenges have failed` | DNS doesn't point to the server yet, or port 80 is blocked (`ufw status`, Hetzner firewall in the Cloud Console). |
| nginx test: `host not found in upstream "eventmanager-web"` | The web container isn't running → `sudo docker compose logs web` in `/opt/docker/eventmanager`. |
| 502 Bad Gateway | `web` is still starting (migrations + collectstatic) or crashed → same logs. |
| `/static/` gives 404 | collectstatic hasn't run yet (web logs); the nginx container mounts `/opt/docker/eventmanager/data/static` read-only. |
