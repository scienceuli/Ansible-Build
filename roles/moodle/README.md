---
kind: application
---

<img src="/logos/moodle.png" alt="moodle logo" width="100" height="100">

# Moodle role

Deploy Moodle Docker container.

## Usage

Configure the role.

```yml
# https://hub.docker.com/r/erseco/alpine-moodle (nginx + php-fpm on port 8080,
# cron runs inside the container). Pin a version tag, not latest.
moodle_image: erseco/alpine-moodle:v5.3.0
moodle_hostname: moodle01
moodle_volume_name: moodle_data01 # default: "{{ moodle_hostname }}"
moodle_code_volume_name: moodle_code01 # default: "{{ moodle_hostname }}_code"
# Behind a TLS-terminating reverse proxy (nginx_proxies -> moodle01:8080)
moodle_site_url: https://moodle.example.com # default: http://localhost
moodle_sslproxy: "true" # default: "false"
moodle_reverseproxy: "false" # only for multiple base URLs
moodle_username: admin
moodle_password: "{{ vault_moodle_password }}"
moodle_email: moodle@example.com
moodle_site_name: "School of Example"
moodle_language: de # default: en
moodle_database_type: mariadb # default: mariadb (also mysqli, pgsql)
moodle_database_host: mariadb02
moodle_database_port: "3306" # default: "3306", pgsql: "5432"
moodle_database_name: moodle
moodle_database_user: moodle
moodle_database_password: "{{ vault_moodle_database_password }}"
moodle_smtp_host: mail.example.com
moodle_smtp_port: "465" # default: "587"
moodle_smtp_user: bot@example.com
moodle_smtp_password: "{{ vault_moodle_smtp_password }}"
moodle_smtp_protocol: ssl # default: tls
moodle_mail_noreply_address: noreply@example.com # default: "{{ moodle_smtp_user }}"
moodle_php_max_upload_filesize: 128M # default 50M (php + nginx in the container)
moodle_volume_backup_set: # See restic_backup_set var in role restic
```

Put the config in `host_vars/<host>/moodle.yml` (secrets in `moodle_vault.yml`)
and add the host to the `moodle` group of the inventory:

```yml
moodle:
  hosts:
    hertz:
```

Then run [playbooks/moodle.yml](../../playbooks/moodle.yml), which deploys the
database role first:

```yml
- hosts: moodle
  roles:
    - role: mariadb
    - role: moodle
```

## How it works

Example: `./task play -i inventories playbooks/moodle.yml -l hertz`.

### Playbook run

```mermaid
flowchart TD
    A["./task play -i inventories playbooks/moodle.yml -l hertz"] --> B["ansible-playbook"]

    subgraph INV["1 - Load inventory and variables (local)"]
        B --> C["inventories/hosts.yml<br/>group moodle = hertz<br/>-l hertz keeps only hertz"]
        C --> D["group_vars/setup<br/>docker_network_name, restic repo"]
        C --> E["host_vars/hertz/<br/>vars.yml, vault.yml<br/>moodle.yml, moodle_vault.yml"]
        E --> F["Decrypt vault values<br/>with .vault-pass"]
    end

    F --> G["SSH to hertz.science-and-more.com<br/>become root, gather facts"]

    subgraph MDB["2 - Role mariadb (tag mariadb)"]
        G --> H{"mariadb_image defined?"}
        H -- yes --> I["Create docker volume mariadb02"]
        I --> J["Start container mariadb02<br/>mariadb:11.4, utf8mb4_unicode_ci<br/>creates database + user moodle"]
        J --> K["Copy docker-mysql-backup scripts<br/>to /usr/local/bin"]
    end

    subgraph MOO["3 - Role moodle (tag moodle)"]
        K --> L{"moodle_image defined?"}
        L -- yes --> M["Role docker_volume<br/>copy docker-volume-* scripts<br/>create moodle_data01 + moodle_code01"]
        M --> N["Start container moodle01<br/>erseco/alpine-moodle:v5.3.0<br/>env: SITE_URL, DB_*, SMTP_*, SSLPROXY"]
    end

    N --> O["Play done"]

    O -.-> P["Not part of this play:<br/>playbooks/proxy.yml -l hertz - nginx vhost + certificate<br/>restic role -t restic -l hertz - backup cron jobs"]
```

### Runtime on the host

```mermaid
flowchart LR
    U["Browser"] -- "https://staging.moodle.vfll.de" --> NG

    subgraph HERTZ["hertz - docker network science-and-more.com"]
        NG["nginx01<br/>TLS with Let's Encrypt<br/>certbot01 renews"] -- "http://moodle01:8080" --> MO
        NG -- "oonc.vfll.de" --> NC["nextcloud01"]
        NG -- "office.vfll.de" --> OO["doc01"]

        MO["moodle01<br/>nginx + php-fpm + cron"] -- "mariadb02:3306" --> DB2["mariadb02<br/>DB moodle"]
        NC --> DB1["mariadb01<br/>DB nextcloud"]

        MO --- V1[("moodle_code01<br/>/var/www/html")]
        MO --- V2[("moodle_data01<br/>/var/www/moodledata")]
    end

    MO -- "SMTP 587 tls" --> SMTP["w00a9289.kasserver.com"]

    subgraph BACKUP["root cron on hertz, 02:xx"]
        CR1["docker-mysql-backup<br/>mariadb02 / moodle"]
        CR2["docker-volume-backup<br/>volumes of moodle01"]
    end
    CR1 -.-> DB2
    CR2 -.-> V1
    CR2 -.-> V2
    CR1 --> R["restic-main<br/>backup.science-and-more.com/hertz"]
    CR2 --> R
```

### Container start

Later starts skip the installer and run the database upgrade instead.

```mermaid
sequenceDiagram
    participant D as Docker
    participant M as moodle01
    participant DB as mariadb02
    D->>M: start container
    M->>M: sync Moodle code into moodle_code01 if versions differ
    M->>DB: wait until port 3306 answers
    alt no config.php yet
        M->>M: generate config.php (wwwroot, dbcollation, sslproxy)
        M->>DB: install database (about 500 tables, admin user)
    else config.php exists
        M->>DB: run admin/cli/upgrade.php
    end
    M->>M: start nginx :8080, php-fpm, internal cron
```

## Pitfalls

* `moodle_site_name`: the image passes it unquoted to the installer, so the role
  replaces spaces with `_`. Rename the site afterwards in the admin UI.
* MariaDB >= 11 defaults to `utf8mb4_uca1400_ai_ci`, which fails Moodle's
  unicode check. Set `mariadb_command: "--character-set-server=utf8mb4
  --collation-server=utf8mb4_unicode_ci"` before the first start; the installer
  writes the collation into `config.php`.
* Deploy Moodle before the proxy: `nginx -t` fails while `moodle01` is not
  running, and nginx keeps its old config until a reload succeeds.
