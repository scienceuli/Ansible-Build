---
kind: system
---

# Compose Postgres restore role

Replaces the database of a docker compose stack's Postgres service with a
`pg_dump -Fc` dump from the control machine. Stops the app services, drops
and recreates the database, restores the dump in a single transaction,
removes the dump from the host again and restarts the app services (whose
entrypoint runs the migrations).

Not meant for playbooks directly - app roles include it when a restore is
requested, e.g. `eventmanager_restore_dump` / `vfllcms_restore_dump`:

```sh
uv run ansible-playbook -i inventories playbooks/eventmanager/playbook.yml \
  -l faraday,faraday_eventmanager_staging -e eventmanager_restore_dump=$HOME/dumps/eventmanager.pgdump
```

Variables: see `defaults/main.yml`.
