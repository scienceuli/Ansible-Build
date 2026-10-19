# homebox + nextcloud

Two independent services on `dirac`, both fronted by nginx on the same host:

- `homebox.example.com` -> HomeBox (roles/homebox) - single Go container, embedded SQLite
- `cloud.example.com`   -> Nextcloud (roles/nextcloud) - app + Postgres + Redis, three containers

## Before running

    ansible-galaxy collection install -r requirements.yml

Set the real domains and Let's Encrypt contact address in
`inventories/host_vars/dirac/vars.yml` (plaintext, committed):

    homebox_domain: "homebox.sam-projekte.de"
    nextcloud_domain: "cloud.homebox.sam-projekte.de"
    letsencrypt_email: "uk@science-and-more.de"
    nextcloud_db_password: "{{ vault_nextcloud_db_password }}"
    nextcloud_admin_password: "{{ vault_nextcloud_admin_password }}"

Nextcloud credentials (HomeBox needs none) live in the sibling
`inventories/host_vars/dirac/vault.yml`, which is
`ansible-vault` encrypted and referenced by the `vault_*` names above:

    vault_nextcloud_db_password: "..."
    vault_nextcloud_admin_password: "..."

To edit it: `ansible-vault edit inventories/host_vars/dirac/vault.yml`.
Both files sit in the same `host_vars/dirac/` directory, so Ansible merges
them automatically.

The vault password itself lives in `.vault-pass` (gitignored, `chmod 600`,
vault-id `scienceuli`) at the repo root, referenced via `vault_identity_list`
in `ansible.cfg` — so no `--ask-vault-pass` / `--vault-password-file` flag
is needed on any command.

## Run

    ansible-playbook -i inventories playbooks/homebox/playbook.yml

To only update the HomeBox container (re-render docker-compose.yml, pull
the image and recreate the container if it changed) without touching any
other role:

    ansible-playbook -i inventories playbooks/homebox/playbook.yml --tags homebox_compose

## TLS / Let's Encrypt

Both roles now issue their own certs via the shared `certbot_host` role
(webroot method, HTTP-01 challenge). Sequence per app:

1. Deploy an HTTP-only vhost so `/.well-known/acme-challenge/` is
   reachable on port 80.
2. Run `certbot certonly --webroot` for that domain if no cert exists yet.
3. Re-render the vhost with the HTTPS server block and reload nginx.

This requires:

- `{{ domain }}` already resolving (in real DNS) to this host, and
  port 80 reachable from the internet — Let's Encrypt has to be able
  to fetch the challenge file.
- `letsencrypt_email` set (used for expiry/problem notifications).

The `certbot` apt package installs its own systemd timer for
automatic renewal; a deploy-hook
(`/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh`) reloads
nginx after any future renewal, for any domain on the host — you
don't need to re-run Ansible just to pick up a renewed cert.

Set `homebox_enable_ssl: false` / `nextcloud_enable_ssl: false` for
plain HTTP vhosts if you're terminating TLS elsewhere (e.g. an
upstream load balancer).

## Other notes
- `nextcloud_client_max_body_size` defaults to 10G since Nextcloud is
  a general file store; HomeBox's is much smaller (50m) since it's
  mostly photos/PDFs of items.
- If you later want to store bulky item documentation (manuals,
  warranty PDFs) in Nextcloud rather than HomeBox's own storage, the
  simplest approach is just pasting a Nextcloud share link into the
  item's notes/URL field in HomeBox - no integration code needed.
