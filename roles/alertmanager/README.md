---
kind: service
---

# Alertmanager role

Deploy Prometheus Alertmanager container. Receives the alerts of the Prometheus rules
(`host_vars/<host>/rules.yml`, prometheus role) and sends them by mail.

## Usage

Configure the role.

```yml
alertmanager_hostname: alertmanager02
alertmanager_smtp_smarthost: smtp.example.com:587
alertmanager_smtp_from: alertmanager@example.com
alertmanager_smtp_auth_username: bot@example.com
alertmanager_smtp_auth_password: "{{ vault_smtp_password }}"
alertmanager_mail_to: admin@example.com
alertmanager_image: prom/alertmanager:v0.35.0 # default
alertmanager_port: 127.0.0.1:9093 # default
alertmanager_external_url: http://localhost:9093 # default
alertmanager_repeat_interval: 12h # default
```

Point Prometheus to it (prometheus role):

```yml
prometheus_alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager02:9093"]
```

And include it in your playbook.

```yml
- hosts: example
  roles:
  - role: alertmanager
```

## Docs

UI (active alerts, silences): `ssh -L 9093:127.0.0.1:9093 example`, then open
<http://localhost:9093>. Check the config:
`docker exec alertmanager02 amtool check-config /etc/alertmanager/alertmanager.yml`.
