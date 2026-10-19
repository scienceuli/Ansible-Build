# How it works: Ansible explained with the HomeBox deploy

This page walks through what Ansible actually does when HomeBox is deployed
on `dirac`: which files it reads, which **decisions** it takes on the way,
and why. The examples focus on two roles: `docker` (installs Docker) and
`restic` (backs up the HomeBox database).

## 1. The building blocks

| Term | What it is | HomeBox example |
|------|------------|-----------------|
| **Inventory** | *Which* machines exist, how to reach them, which groups they belong to | `inventories/hosts.yml` |
| **Variables** | Configuration values, attached to groups or single hosts | `inventories/group_vars/…`, `inventories/host_vars/dirac/` |
| **Task** | One step that describes a *desired state* ("package X installed", "file Y has this content") | "Deploy docker-compose.yml" |
| **Role** | A reusable bundle of tasks + defaults + templates + handlers for one job | `roles/docker`, `roles/homebox`, `roles/restic` |
| **Play** | "Apply *these roles* to *these hosts*" | "Deploy HomeBox" → `hosts: dirac` |
| **Playbook** | A file with one or more plays, run top to bottom | `playbooks/homebox/playbook.yml` |
| **Tag** | A label on tasks/roles so you can run only a part of a playbook | `homebox_compose`, `restic` |
| **Handler** | A task that runs only when another task *notified* it about a change | "Restart docker service" |

The important idea: tasks don't say *"do X"*, they say *"X should be true"*.
Ansible checks the current state first and only changes something if it
differs. That's why you can re-run a playbook safely (**idempotency**), and
why the output says `ok` (already fine) or `changed` (Ansible fixed it).

## 2. Inventory: who is `dirac`?

From `inventories/hosts.yml` (shortened):

```yaml
all:
  children:
    setup:
      children:
        debian13:
          hosts:
            dirac:
              ansible_host: dirac.science-and-more.com
              ansible_user: scienceuli
```

So `dirac` is a member of three groups: `all` → `setup` → `debian13`.
Group membership decides which variable files apply:

```
inventories/
├── group_vars/
│   ├── setup/vars.yml     ← applies to dirac (member of "setup")
│   ├── setup/vault.yml    ← encrypted secrets for "setup"
│   └── debian13.yml       ← applies to dirac (member of "debian13")
└── host_vars/
    └── dirac/
        ├── vars.yml       ← only dirac
        └── vault.yml      ← only dirac, encrypted
```

What lands where, and why:

- `debian13.yml` holds what depends on the **OS**: the Docker apt repo for
  Debian *trixie*, the `docker_packages` list, the base `group_packages`.
- `setup/vars.yml` holds what's the same on **every managed server**: the
  restic server address, Docker Hub login user, timezone, …
- `host_vars/dirac/vars.yml` holds what's specific to **this machine**: the
  HomeBox domain, the pinned image tag, the restic backup jobs.

## 3. Where a variable's value comes from (precedence)

The same variable can be set in several places. Lowest to highest
priority (simplified):

1. **Role defaults** – `roles/<role>/defaults/main.yml` (fallback values)
2. **Group vars** – `group_vars/all` < `group_vars/setup` < `group_vars/debian13`
   (child group beats parent group)
3. **Host vars** – `host_vars/dirac/…`
4. **Play/role vars** – `vars:` written in the playbook
5. **Extra vars** – `-e name=value` on the command line (always wins)

Example: `homebox_image_tag`

| Where | Value |
|-------|-------|
| `roles/homebox/defaults/main.yml` | `"latest"` |
| `inventories/host_vars/dirac/vars.yml` | `"0.27.0"` ← **wins** |

Because role defaults have the lowest priority, a role works out of the box
and every host can override only what it needs.

Secrets follow the same rules: `vault.yml` files are encrypted with
`ansible-vault`, and plain vars point at them
(`restic_repo_password: "{{ vault_restic_repo_password }}"`). `ansible.cfg`
tells Ansible where the vault password file is, so it decrypts them
transparently.

## 4. The HomeBox playbook, play by play

```
ansible-playbook -i inventories playbooks/homebox/playbook.yml
```

```
Play 1 "Bootstrap host"   hosts: dirac  →  docker, nginx_host, mosquitto
Play 2 "Deploy HomeBox"   hosts: dirac  →  homebox, label_watcher, backup
Play 3 "Deploy Nextcloud" hosts: dirac  →  nextcloud
```

For each play Ansible:

1. Picks the hosts matching `hosts:` from the inventory.
2. **Gathers facts**: connects via SSH and collects data about the machine
   (`ansible_distribution: Debian`, `ansible_distribution_major_version: 13`,
   IPs, …). Many decisions below are based on these facts.
3. Runs the roles' tasks in order, each one on every host.
4. Runs notified **handlers** at the end of the play (or earlier at a
   `meta: flush_handlers`).

`become: true` means: connect as `scienceuli`, run tasks as root via sudo.

## 5. The `docker` role: the decisions

Goal: Docker Engine + compose plugin installed, configured and running.
Entry point is `roles/docker/tasks/main.yml`, which mostly **decides which
other task files to include**.

```
roles/docker/tasks/main.yml
│
├─ always ─────────────────────────────► docker_scripts.yml
│                                          copy docker-export / docker-import
│
├─ docker_packages defined?  ── no ──► skip everything below (except login)
│   │ yes (from group_vars/debian13.yml)
│   │
│   ├─ ansible_distribution == ?   (fact, gathered at play start)
│   │    Ubuntu ─► docker-ubuntu.yml
│   │    Debian ─► docker-debian.yml   ◄── dirac
│   │    CentOS ─► docker-centos.yml
│   │    Rocky  ─► docker-rocky.yml
│   │
│   └─ docker.yml  (OS-independent config)
│
└─ docker_login_username defined? ── yes (group_vars/setup) ─► docker-login.yml
```

### Decision 1: "Which OS is this?"

The role supports four distributions. It doesn't ask you; it reads the
`ansible_distribution` **fact**. On `dirac` that's `Debian`, so only
`docker-debian.yml` is included, the others are skipped.

### Decision 2: "Where do packages come from?"

`docker-debian.yml` doesn't hardcode repository URLs. It uses
`docker_apt_url` / `docker_apt_repo` from `group_vars/debian13.yml`
(`… debian trixie stable`). A Debian 12 host gets `bookworm` from
`group_vars/debian12.yml` with the **same role code**. That's the point of
putting OS details into group vars.

Steps, each one idempotent:

1. Ensure `gnupg` is installed (needed for signed repos).
2. Download Docker's GPG key to `/etc/apt/keyrings/docker.asc`.
3. Add the Docker apt repository (skipped if already present).
4. Install `docker_packages` by **reusing another role**:
   ```yaml
   - ansible.builtin.include_role:
       name: packages
     vars:
       group_packages: "{{ docker_packages }}"
   ```
   The `packages` role normally installs the base package list; here it's
   called with the Docker list instead. No duplicated "install packages"
   logic.

### Decision 3: "Does the daemon config need to change?"

`docker.yml` renders `templates/daemon.json` (data dir, log driver, log
rotation, IPv6) to `/etc/docker/daemon.json`:

```yaml
- name: Copy docker daemon config
  ansible.builtin.template: ...
  notify: Restart docker service
```

- File content **unchanged** → task is `ok`, nothing else happens.
- File content **changed** → task is `changed` and *notifies* the handler.
  The handler restarts Docker once at the end of the play, even if several
  tasks notified it.

So Docker is only restarted when its config really changed, not on every
run.

### Decision 4: "Log in to Docker Hub?"

Only if `docker_login_username` is defined (it is, in `group_vars/setup`).
The role first checks with `id <user>` which users from
`docker_login_users` exist and only logs in for those.

## 6. The `homebox` role in short

1. Create `/opt/docker/homebox`, `data/`, `labels/` directories.
2. Render `docker-compose.yml` from the template (image + tag, port, env).
3. `docker compose up`, with a **decision about pulling**:
   ```yaml
   pull: "{{ 'always' if (homebox_compose_file.changed or 'homebox_compose' in ansible_run_tags) else 'missing' }}"
   ```
   - compose file changed (e.g. new image tag) → pull
   - run explicitly with `--tags homebox_compose` → pull
   - otherwise → only pull if the image doesn't exist locally at all
4. nginx vhost + Let's Encrypt certificate (only requested if no cert exists
   yet).

## 7. The `restic` role: the decisions

Goal: every night, take a **consistent** copy of the HomeBox SQLite
database and push it to the restic server `backup.science-and-more.com`.

Note: restic is **not** part of the HomeBox playbook. It's a server-wide
concern and runs from `playbooks/setup.yml` (role tagged `restic`). That's
why the job is described in `host_vars/dirac/vars.yml` and the path is
spelled out instead of using `homebox_data_dir`: in the setup play the
homebox role's defaults aren't loaded.

```yaml
# inventories/host_vars/dirac/vars.yml
restic_backup_set:
  - id: "Backup Homebox"
    type: sqlite
    name: homebox
    path: /opt/docker/homebox/data
    database: homebox.db
    tags: [homebox]
    hour: "3"
```

Run it with:

```
ansible-playbook -i inventories playbooks/setup.yml -l dirac --tags restic
```

### Decision 1: "Is there a repository configured at all?"

```yaml
- include_tasks: restic.yml
  when: restic_repo is defined and restic_repo
```

`restic_repo` comes from `group_vars/setup/vars.yml`:
`backup.science-and-more.com/{{ inventory_hostname }}`. Every host gets its
**own** repository on the server (`…/dirac`), from one line of config.

`restic.yml` then:

1. Ensures `restic` is installed, the `backup` group and `/var/backup` exist.
2. **Decides the repository type** (`restic_repo_type`, default `rest`) and
   builds the URL with user/password URL-encoded into it.
3. Writes `/usr/local/bin/restic-main`, a wrapper with repository and
   password baked in, so cron jobs can simply call `restic-main backup …`.

### Decision 2: "Does the repository already exist?"

```yaml
- name: Check if repo is initialized
  command: restic snapshots
  ignore_errors: true
  changed_when: false
  register: repo_initalized

- name: Init restic repository
  command: restic init
  when: repo_initalized.failed
```

`restic init` is not idempotent by itself (it fails on an existing repo).
So the role **probes first** and only initializes on the very first run.
This "check, register, act on the result" pattern is how you make plain
shell commands idempotent.

### Decision 3: "Which kind of backup is this?"

`main.yml` includes one task file per backup type. Each one loops over
**all** entries of `restic_backup_set` and acts only on its own type:

```yaml
loop: "{{ restic_backup_set }}"
when: item.type == "sqlite"
```

For HomeBox (`type: sqlite`), `restic_sqlite_backup.yml` decides:

- **Is there any sqlite job?** Only then copy the helper script
  `restic-sqlite-backup` and install `sqlite3` + `rsync`.
- **Does the database exist?** `stat` on `/opt/docker/homebox/data/homebox.db`,
  and fail the run if it doesn't. Better to fail at deploy time than to
  discover months later that the nightly job backed up nothing.
- **Register the cron job.**

### Decision 4: "How to back up a database that's in use?"

Copying `homebox.db` while HomeBox writes to it can produce a broken file.
So the cron job doesn't back up the live directory directly:

```
restic-sqlite-backup -s /opt/docker/homebox/data -d homebox.db -o /var/backup/homebox \
  && restic-main backup /var/backup/homebox --tag homebox ; \
  write-node-exporter-metric -c 'Backup Homebox' -v $?
```

1. `rsync` everything except the DB (and its `-wal`/`-shm` files) to
   `/var/backup/homebox`.
2. `sqlite3 .backup` makes a consistent copy of the DB, `PRAGMA
   integrity_check` verifies it, only then it replaces the previous copy.
3. `&&`: only if that succeeded, restic uploads the staged directory.
4. The exit code is written as a metric for monitoring (Grafana).

### Decision 5: "When exactly does it run?"

```yaml
hour: "{{ item.hour }}"                        # 3
minute: "{{ 59 | random(seed=item.id) }}"
```

The minute is "random" but **seeded with the job id**: always the same for
"Backup Homebox", but different jobs/hosts don't all hit the backup server at
03:00 sharp. A truly random minute would change on every run and make the
task report `changed` every time.

The cron entry is identified by its `name` (= `id`). That's how Ansible
finds and updates *its* entry instead of adding a new line on each run.
Consequence: don't rename the `id` later, or you'll end up with two entries
(see `roles/restic/README.md`, "Rename cron job").

Finally, a rotation job (23:xx) runs `restic forget … --prune` with the
`restic_backup_rotation` policy (last 14, daily 14, weekly 4, monthly 3).

### Two backups for HomeBox

HomeBox is actually backed up twice, by different roles and playbooks:

| | `backup` role (HomeBox playbook) | `restic` role (setup playbook) |
|---|---|---|
| Target | Nextcloud via WebDAV (rclone) | restic server `backup.science-and-more.com` |
| When | 03:15 | 03:xx (seeded minute) |
| History | dated folders, 14 days | restic snapshots, rotation policy |
| Config | `vars:` in `playbooks/homebox/playbook.yml` | `restic_backup_set` in `host_vars/dirac` |

## 8. Tags: running only a part

Without tags, a playbook runs everything. With `--tags X`, only tasks
carrying tag `X` run. Everything else is skipped (fact gathering still
runs).

```
# only re-render compose file + pull + restart HomeBox
ansible-playbook -i inventories playbooks/homebox/playbook.yml --tags homebox_compose

# only (re)configure restic on dirac
ansible-playbook -i inventories playbooks/setup.yml -l dirac --tags restic

# see what *would* run, without touching the server
ansible-playbook -i inventories playbooks/homebox/playbook.yml --tags homebox_compose --list-tasks
```

Tasks can also check which tags were requested via `ansible_run_tags`; the
homebox role uses that to force an image pull when you run
`--tags homebox_compose`.

### Gotcha: tags on a role vs. tags on `include_tasks`

Where a tag is placed matters:

```yaml
# playbooks/setup.yml: tag on the role → every task of the role,
# including tasks in files pulled in by include_tasks, gets "restic".
- role: restic
  tags: restic
```

```yaml
# roles/docker/tasks/main.yml: tag on an include_tasks task → only the
# include itself is tagged, NOT the tasks inside docker-debian.yml.
- include_tasks: docker-debian.yml
  tags: [docker]
```

So `--tags restic` on `setup.yml` does the full restic setup, but
`--tags docker` on the HomeBox playbook only *includes* the docker files
and then skips every task in them. Nothing gets installed. (Checked with a
minimal test playbook.) If you want `--tags docker` to work there, tag the
role in the playbook (`- role: docker` + `tags: docker`) the same way
`setup.yml` does.

## 9. Cheat sheet

| I want to… | Command |
|------------|---------|
| Full deploy | `ansible-playbook -i inventories playbooks/homebox/playbook.yml` |
| Update HomeBox to a new version | set `homebox_image_tag` in `host_vars/dirac/vars.yml`, then `--tags homebox_compose` |
| Dry run (show changes, change nothing) | add `--check --diff` |
| See tasks per tag | add `--list-tasks` |
| Limit to one host | add `-l dirac` |
| Set up / change restic jobs | `playbooks/setup.yml -l dirac --tags restic` |
| Edit secrets | `ansible-vault edit inventories/host_vars/dirac/vault.yml` |
