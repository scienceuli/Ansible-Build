#!/bin/sh
# Installed by Ansible (roles/certbot) - reloads nginx after any certbot renewal.
systemctl reload nginx
