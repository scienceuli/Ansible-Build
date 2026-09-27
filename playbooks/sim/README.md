# SIM (Django + LaTeX invoices) on noether

Dockerized Django app (gunicorn, plain HTTP on the LAN): `http://10.0.1.33:8000`.
The names `noether` / `noether.sam.com` are accepted by Django
(`sim_allowed_hosts`) but only work in a browser or `ssh` if they resolve on
your machine (local DNS or `/etc/hosts`).

## Deploy

    ansible-galaxy collection install -r playbooks/sim/requirements.yml
    ansible-playbook -i inventories playbooks/sim/playbook.yml

The source comes from the private GitHub repo (`sim_git_repo`, branch
`sim_git_version`, default `main`): push your changes first, then re-run. The
role pulls them into `/opt/docker/sim/src` on noether and rebuilds the image
(layer cache keeps it fast when only app code changed).

### First run: authorize the deploy key

The role generates an SSH key on noether (`/opt/docker/sim/deploy_key`, the
private half never leaves the server). The first run stops at the git step and
prints the public key: add it as a **read-only Deploy key** on the repo
(GitHub: Settings > Deploy keys), then re-run. GitHub's host key is pinned in
the role, so the connection is verified rather than blindly trusted.

## Configuration

`inventories/host_vars/noether/`: `vars.yml` (git repo, allowed
hosts, ...) and `vault.yml` (Django `SECRET_KEY`, SMTP user/password).
`sim/settings.py` reads them from the environment (`DJANGO_*`, `EMAIL_*`),
with defaults that keep local development unchanged.

## Data

- The SQLite DB lives in `/opt/docker/sim/data` (mounted at `/data`). It is
  seeded once from `sim_initial_db`; later runs never overwrite it.
- Customer data (`data/`, `db.sqlite3`) is not in the git repo and is excluded
  from the image (`.dockerignore`) - keep it that way.
- There is no backup of this DB yet.

## LaTeX

`pdflatex` and the TeX Live subset live in the image (see the `Dockerfile` in
the SIM project), not on the host. The build fails early if a TeX file the
invoice templates need is missing.

## Admin user

    ssh -t scienceuli@10.0.1.33 "sudo docker exec -it sim python manage.py createsuperuser"

`-t` is required: `docker exec -it` needs a terminal, and `ssh` only allocates
one for a remote command when asked.
