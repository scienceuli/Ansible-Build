# flask_info on raspizero

Flask app (venv + gunicorn + nginx, plain HTTP on the LAN) on a Raspberry Pi
Zero (Debian 11, `armv6l`, 429 MB RAM - keep dependencies light).
`http://10.0.1.71` / `http://flask_info.scienceuli.com` (the latter only
resolves if you've set that up locally; it's not a public domain).

## Deploy

    ansible-playbook -i inventories playbooks/flask_app/playbook.yml

The source comes from the private GitHub repo (`app_repo`, branch
`app_branch`): push your changes first, then re-run. The role pulls them into
`{{ app_dir }}` (`/opt/flask_info`) and restarts gunicorn if anything changed.

### First run: authorize the deploy key

The role generates an SSH key on raspizero (`{{ app_dir }}/.ssh/deploy_key`,
owned by `{{ app_user }}` (`www-data`), private half never leaves the
server). The first run stops at the git step and prints the public key: add
it as a **read-only Deploy key** on the repo (GitHub: Settings > Deploy
keys), then re-run. GitHub's host key is pinned in the role, so the
connection is verified rather than blindly trusted.

## Configuration

`inventories/host_vars/raspizero/`: `vars.yml` (repo, port, server_name,
CalDAV URL/username, ...) and `vault.yml` (`vault_caldav_password`).
`fetch_calendar.py` reads `CALDAV_URL`/`CALDAV_USERNAME`/`CALDAV_PASSWORD`
from the environment (deployed to `{{ app_dir }}/.env`).

## Data

- The SQLite DB (`infocenter.db`) lives in `{{ app_dir }}` and is created on
  first start by `app.py`'s `init_db()` - nothing to seed.
- There is no backup of this DB. Low-stakes (notes for an e-ink display), but
  the `backup` role (see `roles/backup`, used for HomeBox/SIM) could cover it
  the same way if you want one.

## Not yet set up

- No periodic cron for `render_display.py` (calendar refresh) - it currently
  only runs on-demand when a note is submitted via the web form. The
  original manual instructions in `flask_info`'s own README describe a
  `*/15 * * * *` cron entry; add an `ansible.builtin.cron` task to the role
  if you want that automated.
- No HTTPS - this is plain HTTP on the LAN, same as `sim` on `noether`.
