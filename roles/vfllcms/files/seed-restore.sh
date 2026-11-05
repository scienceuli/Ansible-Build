#!/bin/sh
# docker-entrypoint-initdb.d script: the official postgres image runs every
# *.sh/*.sql in this directory, but only once -- the very first time it
# starts against an empty data directory. Restores the pg_dump (custom
# format) that docker-compose.yml.j2 bind-mounts next to this script.
set -e

pg_restore --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    /docker-entrypoint-initdb.d/seed.pgdump
