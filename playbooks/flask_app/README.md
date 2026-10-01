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

The role generates an SSH key on raspizero (`{{ app_deploy_key_path }}`,
default `/etc/flask_info/deploy/deploy_key`, owned by `{{ app_user }}`
(`www-data`), private half never leaves the server - kept outside `app_dir`
since `git clone` needs an empty target directory). The first run stops at
the git step and prints the public key: add
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

## Waveshare Display (7.5inch e-Paper HAT)

Setup guide: https://www.waveshare.com/wiki/7.5inch_e-Paper_HAT_Manual#Working_With_Raspberry_Pi.
What that guide covers vs. what's actually needed here differ in a few ways
(checked against the driver source, not just the wiki text):

- **SPI enable + reboot**: automated. `waveshare_display_enabled: true` (set
  in `inventories/host_vars/raspizero/vars.yml`) makes the role ensure
  `dtparam=spi=on` in `/boot/config.txt` and reboot if that line was just
  added. Already enabled on raspizero from your manual test, so this is
  normally a no-op.
- **`www-data` group membership**: automated, and *not* mentioned by the
  wiki - it assumes you run as `pi` (in the `spi`/`gpio` groups by default on
  Raspberry Pi OS). gunicorn runs as `www-data`, which isn't, so the role
  adds it to both groups.
- **Python deps**: `spidev` and `gpiozero` are in `requirements.txt` (venv,
  matching how the rest of this app's deps are managed) instead of the
  wiki's system-wide `apt`/`pip3` install. The wiki also has you install
  `python3-pil` and `python3-numpy` - neither is needed: Pillow is already a
  dependency (see `pillow==11.2.1` in `requirements.txt`), and
  `epdconfig.py`'s actual Raspberry Pi backend doesn't import numpy at all
  (checked the driver source directly - that's generic wiki boilerplate).
- **`lgpio` (gpiozero pin backend)**: automated, installed into the venv by
  the role. Without it gpiozero silently falls back to the legacy
  `/sys/class/gpio` interface, which the trixie kernel on raspitwo rejects
  (`OSError: [Errno 22] Invalid argument` in the gunicorn journal, display
  does nothing). The wiki demos don't hit this because system python has
  `python3-lgpio` from apt.
- **config.txt location**: on Bookworm and later (raspitwo) the role edits
  `/boot/firmware/config.txt`; `/boot/config.txt` is only used where
  `/boot/firmware/` doesn't exist (raspizero, Debian 11).
- **The `waveshare_epd` Python module itself**: **not yet handled**. It's
  not a PyPI package - the wiki has you `git clone
  https://github.com/waveshare/e-Paper.git` and use
  `RaspberryPi_JetsonNano/python/lib/waveshare_epd/` directly. That doesn't
  fit a git-based Ansible deploy well; the plan is to vendor just the needed
  driver files (their license permits redistribution) into the `flask_info`
  repo itself rather than have Ansible clone a second, unrelated repo.
- **`render_display.py`'s hardware output is still a no-op** (commented out).
  Needs to be wired up to whichever driver module gets vendored - worth
  noting the display you actually tested, `epd_7in5b_V2_test.py`, is the
  **three-color (black/white/red)** variant, whose `display()` takes two
  image buffers (black + red), not the one `epd7in5_V2` (two-color) call
  `render_display.py` has commented in right now.
