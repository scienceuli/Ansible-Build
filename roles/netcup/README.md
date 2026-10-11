# netcup role

Manage DNS records of domains hosted at netcup via the CCP DNS API
(https://ccp.netcup.net/run/webservice/servers/endpoint.php). Same record
format as the `vercel` role, so moving a domain over is mostly a rename of
`vercel_dns` to `netcup_dns`.

## Usage

API key and password: CCP > Stammdaten > API. Put them in the vault:

```yml
vault_netcup_customer_number: 12345
vault_netcup_api_key: ...
vault_netcup_api_password: ...
```

Configure the records:

```yml
netcup_dns:
  - domain: example.com
    records:
      - { name: www, type: CNAME, value: example.com., state: present }
      - { name: '', type: A, value: 93.184.216.34, state: present }   # '' or '@' = zone apex
      - { name: '', type: MX, value: mail.example.com, priority: 10, state: present }
      - { name: old, type: A, value: 1.2.3.4, state: absent }
```

And include it in your playbook:

```yml
- hosts: setup
  roles:
  - role: netcup
```

## Behaviour

- Records are matched on name + type. `present` creates a missing record or
  updates the value (and `priority`, if given) of an existing one;
  `absent` deletes every record with that name + type.
- Records in the zone that aren't listed are left untouched.
- One name + type with several values (e.g. multiple TXT or MX records) isn't
  supported for `present`: only the first existing match is compared/updated.
- `--check` logs in and reads the zone, then shows what would be
  created/updated/removed without changing anything.
- netcup applies zone changes with some delay (usually a few minutes).
