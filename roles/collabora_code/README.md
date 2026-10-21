---
kind: application
---

<img src="/logos/collabora_code.png" alt="collabora_code logo" width="100" height="100">

# Collabora Code role

Deploy Collabora Online Development Edition (CODE) container.

## Usage

Configure the role.

```yml
# https://hub.docker.com/r/collabora/code
collabora_code_image: collabora/code:24.04.8.2.1
collabora_code_hostname: collabora01
collabora_code_server_name: doc.example.com
collabora_code_description: Collabora for Nextcloud # default: Collabora Code
collabora_code_port: 9981 # default: 9980
collabora_code_ports: [] # default: ["{{ collabora_code_port }}:9980"], [] behind a proxy on the docker network
collabora_code_username: code # default: admin
collabora_code_password: # default: "{{ vault_collabora_code_password }}"
collabora_code_ssl_enabled: false # default: true
collabora_code_ssl_termination: true # default: false, true when TLS ends at the proxy
# WOPI hosts allowed to use the server, one per aliasgroupN env var
# default: built from collabora_code_host + collabora_code_alias1 (legacy)
collabora_code_aliasgroups:
  - https://next.example.com:443,https://cloud.example.com:443
  - https://moodle.example.com:443
collabora_code_remote_font_config_url: https://next.example.com/apps/richdocuments/settings/fonts.json
collabora_code_extra_params: "" # more --o:key=value options
```

And include it in your playbook.

```yml
- hosts: collabora
  roles:
  - role: collabora_code
```

## Docs

### Nginx config

Behind the `nginx` role on the same docker network (TLS at nginx,
`collabora_code_ssl_enabled: false`, `collabora_code_ssl_termination: true`).
Needs the `$connection_upgrade` map in `nginx_http_options`:

```yml
  - src_hostname: doc.example.com
    dest_hostname: collabora01
    dest_port: 9980
    tls: true
    options: |
      include /etc/nginx/conf.d/proxy-params.conf;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      client_max_body_size 100m;
      proxy_read_timeout 36000s;
```
