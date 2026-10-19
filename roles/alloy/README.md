---
kind: service
---

# Alloy role

Deploy Grafana Alloy container. Collects host metrics (built-in node_exporter) and
container metrics (built-in cAdvisor) and pushes them to Prometheus via remote write.
Prometheus must run with `--web.enable-remote-write-receiver` (prometheus role does).

## Usage

Configure the role.

```yml
# https://hub.docker.com/r/grafana/alloy/tags
alloy_image: grafana/alloy:v1.20.1
alloy_hostname: alloy01
alloy_prometheus_url: http://prom01:9090/api/v1/write
alloy_description: Alloy # default: Grafana Alloy {{ inventory_hostname_short }}
alloy_data_dir: /usr/share/alloy # default: "/usr/share/{{ alloy_hostname }}"
alloy_port: 127.0.0.1:12345 # default
alloy_scrape_interval: 30s # default
alloy_instance: example # default: "{{ inventory_hostname }}"
alloy_unix_enabled: true # default
alloy_cadvisor_enabled: true # default
```

Push to a Prometheus on another host (nginx with basic auth in front of `/api/v1/write`):

```yml
alloy_prometheus_url: https://prometheus.example.com/api/v1/write
alloy_prometheus_basic_auth_username: prometheus
alloy_prometheus_basic_auth_password: "{{ vault_alloy_prometheus_basic_auth_password }}"
```

And include it in your playbook.

```yml
- hosts: example
  roles:
  - role: alloy
```

## Docs

Alloy UI (component graph and health): `ssh -L 12345:127.0.0.1:12345 example`, then
open <http://localhost:12345>.
