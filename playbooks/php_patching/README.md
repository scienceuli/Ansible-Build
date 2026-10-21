# PHP patching

How the PHP of all deployments gets patched, and how to check it. Started with
the PHP security releases of 2026-10-21; the steps apply to every later PHP
release.

## 2026-10-21: CVE-2026-109618 / CVE-2026-109619

<https://www.php.net/archive/2026.php#2026-10-21-5> - two critical bugs (CVSS 9.2,
unauthenticated remote code execution) in every PHP that serves web requests:
PHP-FPM, Apache mod_php (highest risk, exploit runs before any application
code), php-cgi, FrankenPHP, LiteSpeed.

| Branch | Fixed in |
|---|---|
| 8.5 | 8.5.12 |
| 8.4 | 8.4.27 |
| 8.3 | 8.3.36 |
| 8.2 | 8.2.35 (EOL 2026-12-31) |
| ≤ 8.1 | no upstream fix - distro backports only |

### Where PHP runs

Scan of all hosts on 2026-10-21 (`check.yml`):

| Host | Container | Image | PHP | Patch by |
|---|---|---|---|---|
| hertz | `nextcloud01` | `nextcloud:35-apache` | 8.5.11 | new image build → `vfll_nextcloud/migrate.yml` |
| hertz | `moodle01` | `erseco/alpine-moodle:v5.3.0` | 8.4.21 (Alpine 3.23 package) | new image build → `moodle.yml` |
| hertz | native `php8.1-fpm` | Ubuntu package 8.1.2-1ubuntu2.11 | 8.1 | **stopped + disabled 2026-10-21** (old native Nextcloud, retired 2026-10-16); remove with the cleanup of the old instance |
| dirac | `nextcloud-app` | `nextcloud:31-apache` | 8.3.30 | Nextcloud 31 is EOL, its image isn't rebuilt any more → **upgrade to 32** (role default now `32-apache`) |
| gauss | `wordpress` | `vfllwp_wordpress` (built 2025-09 from `wordpress:latest`) | 8.3.25 | not managed here → reinstall, see [../vfll_wordpress/README.md](../vfll_wordpress/README.md) |

No PHP on backup, bbb, bohr, curie, euler, faraday, joule, noether (apache2
without PHP). raspizero/raspitwo were offline - check them when they're up.

### Status on release day

Upstream had no fixed builds yet: `php:8.x-apache`, all `nextcloud:*-apache`
tags and Alpine (3.24/edge: php84 8.4.26, php85 8.5.11) still shipped the old
versions. Until they arrive:

- **Stopgap** in `nextcloud01`, `moodle01`, `nextcloud-app` and `wordpress`:
  `session.upload_progress.enabled = 0` (mitigates CVE-2026-109619 only) via
  `zz-cve-2026-109619.ini` in the image's PHP scan dir, web server reloaded.
  Not persistent - it disappears when the container is recreated with the
  fixed image, which is intended. The other mitigations of the advisory
  (`memory_limit=-1`, small `post_max_size`) would break Nextcloud uploads and
  were not applied.
- Vulnerable containers were stopped by hand on 2026-10-21 - start them again
  after patching (the playbook runs below recreate them anyway).
- On hertz, stopping `moodle01` used to take `nginx01` down (nginx resolves
  `proxy_pass` hosts at startup; a stopped container has no DNS name) - and
  with it Nextcloud, Etherpad, Collabora. Fixed with `nginx_resolver:
  127.0.0.11` (role `nginx`, `host_vars/hertz/vars.yml`): upstreams are
  resolved per request, a stopped app only makes its own domain answer 502.
  Takes effect with `playbooks/proxy.yml -l hertz -t nginx`.

Check whether a fixed build is out (no pull needed):

```sh
# PHP_VERSION of an image tag, read from the registry
img=library/nextcloud tag=35-apache
tok=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$img:pull" | jq -r .token)
A="Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"
m=$(curl -s -H "Authorization: Bearer $tok" -H "$A" https://registry-1.docker.io/v2/$img/manifests/$tag \
  | jq -r '.manifests[] | select(.platform.architecture=="amd64") | .digest')
c=$(curl -s -H "Authorization: Bearer $tok" -H "$A" https://registry-1.docker.io/v2/$img/manifests/$m | jq -r .config.digest)
curl -sL -H "Authorization: Bearer $tok" https://registry-1.docker.io/v2/$img/blobs/$c | jq -r '.config.Env[]' | grep PHP_VERSION
```

Alpine images (moodle) have no `PHP_VERSION` env - look at the php84 package
of the Alpine release instead: <https://pkgs.alpinelinux.org/packages?name=php84>.

## Patching

All PHP roles pull their image on every run (`nextcloud_pull`,
`nextcloud_docker_pull`, `moodle_pull`, `wordpress_pull`, default `true`), so
a rebuilt image behind the same tag gets deployed; a container is only
recreated when the image changed. From the repo root:

```sh
# hertz: Nextcloud (vars/prod.yml pins nextcloud:35-apache) - ~1-2 min downtime
uv run ansible-playbook -i inventories playbooks/vfll_nextcloud/migrate.yml \
  -e @playbooks/vfll_nextcloud/vars/prod.yml

# hertz: Moodle
uv run ansible-playbook -i inventories playbooks/moodle.yml -l hertz -t moodle

# dirac: Nextcloud 31 -> 32 (one major; the entrypoint runs occ upgrade).
# Back up first, there is no downgrade.
uv run ansible-playbook -i inventories playbooks/homebox/playbook.yml

# gauss: new WordPress stack (after the reinstall)
uv run ansible-playbook -i inventories playbooks/wordpress.yml -l gauss -t wordpress
```

Moodle: `erseco/alpine-moodle` rebuilds its version tags, but only gets a
fixed PHP once its Alpine base ships one. If `v5.3.0` stays on 8.4.21 (Alpine
3.23), move to a newer image release.

Then verify:

```sh
uv run ansible-playbook -i inventories playbooks/php_patching/check.yml
```

## check.yml

Runs `php -r 'echo PHP_VERSION;'` in every running container and on the host,
and fails per host on anything below the fixed versions (`php_fixed_versions`
- update them for the next release) or below 8.2. A host without docker
access fails with `no-access` instead of passing silently.

- Runs without sudo (play var `ansible_become: false`, the inventory's
  `ansible_become` would beat the `become` keyword) - membership in the
  `docker` group is enough. bohr, curie and euler have no sudo password in the
  inventory.
- Native distro packages carry backported fixes under an old upstream version
  (e.g. `8.1.2-1ubuntu2.x`) - the check reports them; verify with the package
  changelog (`apt changelog php8.1-fpm`).
