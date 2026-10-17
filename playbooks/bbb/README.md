# BigBlueButton on bbb

BigBlueButton 3.x (`noble-400`) with Greenlight on host `bbb`
(Ubuntu 24.04, Netcup Vfll), installed by the upstream
[bbb-install.sh](https://github.com/bigbluebutton/bbb-install).

Config: `inventories/host_vars/bbb/vars.yml`
(`bbb_install_hostname`, `bbb_install_certbot_email`).

## Requirements

- Fresh Ubuntu 24.04 64-bit, min. 4 cores / 8 GB RAM (16 GB recommended).
- Nothing else on ports 80/443 (bbb-install brings its own nginx).
- DNS A record for `bbb_install_hostname` points to the server
  (`inventories/group_vars/setup/netcup_dns.yml`) - needed for Let's Encrypt.
- Open ports: TCP 22, 80, 443 and UDP 16384-32768. bbb-install sets up UFW
  itself (`-w`).

## 1. Bootstrap (as root)

Fresh server only has `root` with your SSH key. Creates `scienceuli`
(wheel = sudo, docker) and `bot` from `group_vars/setup/iam.yml`:

    uv run ansible-playbook -i inventories playbooks/bootstrap.yml -l bbb

From now on Ansible connects as `scienceuli` and uses sudo
(`ansible_become: true`).

## 2. Configure server

Only the basic roles - **not** the full `setup.yml`: `ufw`/`firehol` would
override the BBB firewall rules, `docker_*`/`k3s` aren't needed (bbb-install
installs Docker for Greenlight):

    uv run ansible-playbook -i inventories playbooks/setup.yml -l bbb \
      -t update,packages,timezone,locale,motd,iam

## 3. Install BigBlueButton

    uv run ansible-playbook -i inventories playbooks/bbb/playbook.yml

Runs `bbb-install.sh` as root (via sudo), takes 15-30 min. Skipped on later
runs once `/usr/bin/bbb-conf` exists. To upgrade, run the script manually on
the server (see role `roles/bbb_install`).

## 4. After install

On the server:

    sudo bbb-conf --check
    sudo bbb-conf --status
    # Greenlight admin account
    sudo docker exec -it greenlight-v3 bundle exec rake \
      admin:create['Name','email@example.com','Password1!']

Then open `https://<bbb_install_hostname>`.
