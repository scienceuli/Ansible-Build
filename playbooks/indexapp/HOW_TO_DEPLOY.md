# Index App – deployment

App: <https://github.com/scienceuli/indexapp> (private). Plan and decisions: `PLAN.md` there.

One docker compose stack per instance (`indexapp_name`, like the eventmanager) in
`/opt/docker/<indexapp_name>` on the docker host:

| container | |
|---|---|
| `<name>` | web: gunicorn; runs `flask db upgrade` on start (nginx `dest_hostname`) |
| `<name>-worker` | RQ worker: PDF annotations → txt/xlsx/Cindex/docx, makeindex + LuaLaTeX |
| `<name>-db` | Postgres 17 |
| `<name>-redis` | job queue + rate limits |

The host's nginx container proxies `indexapp_domain` to `<name>:8000` and serves
downloads from `/opt/docker/indexapp/data` via the `internal` location `/protected-files/`
(X-Accel-Redirect, after the app's permission check). Backups: two `restic_backup_set`
entries in the host's vars (DB dump + data dir).

Instances (inventory group `indexapp`, docker hosts in `indexapp_docker_hosts`):

| inventory host | name | URL | |
|---|---|---|---|
| `lovelace_indexapp` | `indexapp-prod` | **https://editingapps.de** | production; sam-projekte.net, www.* redirect |
| `faraday_indexapp` | `indexapp` | https://indexapp.sam-projekte.de | former interim instance |

Always limit a run to one instance and its docker host:
`-l lovelace,lovelace_indexapp` (production) or `-l faraday,faraday_indexapp`.

## First deployment

```sh
cd ~/Devel/Ansible-Build
ansible-galaxy collection install -r playbooks/indexapp/requirements.yml

# 1. deploy key: prints the public key
ansible-playbook -i inventories/hosts.yml playbooks/indexapp/playbook.yml -l faraday_indexapp -t deploy_key
#    -> GitHub: scienceuli/indexapp -> Settings -> Deploy keys -> add (read-only), or:
#    gh repo deploy-key add key.pub -R scienceuli/indexapp -t faraday-indexapp

# 2. everything (network, app, nginx vhost + certificate)
ansible-playbook -i inventories/hosts.yml playbooks/indexapp/playbook.yml -l lovelace,lovelace_indexapp

# 3. first admin (if no legacy import)
ansible-playbook -i inventories/hosts.yml playbooks/indexapp/playbook.yml -l faraday_indexapp \
  -e indexapp_admin_email=you@example.com -e indexapp_admin_password='…'

# 4. backups (restic sets in host_vars/faraday/vars.yml)
ansible-playbook -i inventories/hosts.yml playbooks/setup.yml -t restic -l faraday
```

Each deploy waits for `/healthz` and runs `flask selftest` in the worker (whole pipeline
incl. LuaLaTeX on a generated PDF).

## Update

`git push` to `main` of the app, then step 2 again (or `-l faraday_indexapp` only: the
source change triggers a rebuild + restart).

## Move an instance to another host (done 2026-11-06: faraday → lovelace)

```sh
# 1. new instance deployed (empty), see above
# 2. maintenance on the old one: stop web + worker (nothing changes any more)
ssh faraday.science-and-more.com 'cd /opt/docker/indexapp && sudo docker compose stop web worker'
# 3. database -> control machine
ssh faraday.science-and-more.com 'sudo docker exec indexapp-db pg_dump -Fc -U indexapp indexapp' > indexapp.pgdump
# 4. files server to server (agent forwarding), then owner = container user
ssh -A lovelace.science-and-more.com 'sudo rsync -a -e "ssh -l scienceuli" --rsync-path="sudo rsync" \
    faraday.science-and-more.com:/opt/docker/indexapp/data/ /opt/docker/indexapp-prod/data/'
# 5. restore the dump into the new instance (stops web/worker, replaces the DB, starts them)
ansible-playbook -i inventories/hosts.yml playbooks/indexapp/playbook.yml -l lovelace,lovelace_indexapp \
  -e indexapp_restore_dump=$PWD/indexapp.pgdump
```

## Import of the legacy app (users, workflows, files)

Replaces **all** data of the new app (`flask migrate-legacy --reset`), so it can be
repeated for rehearsals.

```sh
# a) files from the old server to faraday (~10 GiB) - into the data dir, so the import
#    can hard-link them (faraday has 38 GB; two copies wouldn't fit)
ssh faraday.science-and-more.com 'sudo install -d -o $USER /opt/docker/indexapp/data/_legacy'
ssh -A faraday.science-and-more.com \
  'rsync -a --info=stats1 uli@sam-projekte.net:/home/uli/index_app/project/static/uploads \
                             uli@sam-projekte.net:/home/uli/index_app/project/static/results \
                             /opt/docker/indexapp/data/_legacy/'
# b) dump of the old DB on the control machine (on the old server: sudo -u postgres pg_dump -Fc <db>)
# c) import
ansible-playbook -i inventories/hosts.yml playbooks/indexapp/playbook.yml -l faraday_indexapp \
  -e indexapp_legacy_import=true -e indexapp_legacy_dump=$HOME/Devel/index_app/index_app.dump
```

The summary is printed, the full report is in `/opt/docker/indexapp/migration-report.json`.
The staging folder `data/_legacy` is removed afterwards (the imported files are hard
links); keep it with `-e indexapp_legacy_keep=true` for another rehearsal.

## Operations

```sh
docker logs -f indexapp-web          # requests (gunicorn) + app log
docker logs -f indexapp-worker       # jobs
docker exec indexapp-web flask invite user@example.com --locale de
docker exec indexapp-web flask rerun --status partial --dry-run
journalctl -t indexapp-cleanup       # daily `flask cleanup`
```

## Go-live checklist (end of the test phase)

- `host_vars/faraday/vars.yml`: remove `basic_auth: testing` from the indexapp proxy
- real mail provider: `indexapp_mail_*` in `host_vars/faraday_indexapp` (+ vault)
- after the cut-over of sam-projekte.net: add it (and editingapps.de, www.*) as
  further `nginx_proxies` entries redirecting to the primary domain (PLAN.md)
