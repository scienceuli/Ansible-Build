# OpenTalk

Video conferencing ([opentalk.eu](https://opentalk.eu)), role `opentalk`. Modelled on the
official docker compose "lite" setup <https://gitlab.opencode.de/opentalk/ot-setup>
(profile `core`, release pinned in `opentalk_release`); the OpenTalk ansible repo
(`opentalk/support/ansible`) isn't public.

One compose stack per instance in `/opt/docker/<opentalk_name>`:

| container | | nginx vhost |
|---|---|---|
| `opentalk-web` | web frontend | `talk.vfll.de` → :80 |
| `opentalk-controller` | API, signalling (websocket), internal roomserver | `controller.talk.vfll.de` → :11311 |
| `opentalk-keycloak` | users, OIDC (realm `opentalk`) | `accounts.talk.vfll.de` → :8080 |
| `opentalk-livekit` | media server (SFU) | `livekit.talk.vfll.de` → :7880 |
| `opentalk-db`, `opentalk-keycloak-db` | Postgres 18 | |
| `opentalk-rabbit`, `opentalk-garage` (S3), `opentalk-autoheal` | | |

Media goes **directly** to LiveKit: **7882/udp** (all WebRTC UDP, multiplexed) and
**7881/tcp** (fallback), published by the container (docker ports bypass ufw; open them
in a cloud firewall if there is one). Unlike ot-setup there is no `network_mode: host` and
no 20000–40000/udp range.

Not deployed (yet): etherpad (meeting notes), spacedeck (whiteboard), recorder, SIP
(obelisk), smtp-mailer (email invitations); the matching frontend features are off.

Instances (inventory group `opentalk`, docker hosts in `opentalk_docker_hosts`):

| inventory host | URL |
|---|---|
| `lovelace_opentalk` | **https://talk.vfll.de** |

## First deployment

```sh
cd ~/Devel/Ansible-Build
ansible-galaxy collection install -r playbooks/opentalk/requirements.yml

# 0. DNS (A records -> lovelace, 78.47.220.240): talk.vfll.de (exists),
#    accounts.talk.vfll.de, controller.talk.vfll.de, livekit.talk.vfll.de
#    certbot fails for names that don't resolve yet.

# 1. everything (network, stack, Garage bootstrap, nginx vhosts + certificates)
ansible-playbook -i inventories/hosts.yml playbooks/opentalk/playbook.yml -l lovelace,lovelace_opentalk

# 2. backups (restic sets in host_vars/lovelace/vars.yml)
ansible-playbook -i inventories/hosts.yml playbooks/setup.yml -t restic -l lovelace
```

On the first run the controller restarts until the nginx play has created the accounts
vhost (it loads the OIDC config from `https://accounts.talk.vfll.de/auth/...`). Then:

```sh
ssh lovelace.science-and-more.com 'sudo docker logs --tail 30 opentalk-controller'
curl -s https://accounts.talk.vfll.de/auth/realms/opentalk/.well-known/openid-configuration | head -c 200
```

## Users

Step by step for talk.vfll.de (permanent admin, SMTP, user accounts):
[SETUP_TALK_VFLL.md](SETUP_TALK_VFLL.md). In short:

Keycloak admin: <https://accounts.talk.vfll.de/auth/admin/> – user `admin`, password
`vault_opentalk_keycloak_admin_password` (`ansible-vault view
inventories/host_vars/lovelace_opentalk/vault.yml`). Realm **opentalk** → Users → Add user
(default role `default-roles-opentalk`), set a password under *Credentials*. Self
registration is off. Password-reset mails need SMTP under Realm settings → Email.

The realm is imported from `roles/opentalk/files/keycloak-realm-opentalk.json` only when
it doesn't exist yet; changes later are made in the admin console (and are in the
Keycloak DB backup).

## Update

Bump the image tags in `roles/opentalk/defaults/main.yml` to a newer ot-setup release
(`docker-compose.yaml` of the tag) and re-run step 1. **Read ot-setup's README first**: some
releases need a Postgres dump/restore (major version) or a Keycloak realm export.

## Operations

```sh
cd /opt/docker/opentalk && sudo docker compose ps
sudo docker logs -f opentalk-controller
sudo docker logs -f opentalk-livekit
sudo docker exec opentalk-garage /garage bucket info opentalk
```
