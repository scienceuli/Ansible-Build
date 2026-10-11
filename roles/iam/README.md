---
kind: environment
---

<img src="/logos/iam.png" alt="iam logo" width="100" height="100">

# IAM role

Identity and Access Management. Configure user and groups.

## Usage

Configure the role.

```yml
iam_root_password: "{{ vault_iam_root_password }}"
iam_groups:
  - name: wheel
    sudoers_commands: ALL
  - name: guests
  - name: operator
    sudoers_commands: /usr/bin/docker ps, /usr/bin/docker start *,  /usr/bin/docker stop *, /usr/bin/docker restart *
host_iam_groups:
  - name: backup
iam_users:
  - username: admin
    state: present
    comment: "Administrator"
    ssh_public_key: "ssh-rsa ANzaC1yc2EA...KHgKLVcBaeKQ== admin@example.com"
    groups:
      all: wheel,docker
      server1: operator
    shell: /bin/zsh
    zshrc: |
      PROMPT="$fg[cyan]%}$USER@%{$fg[blue]%}%m ${PROMPT}"
    hosts:
      - server1
      - server2
  - username: bot
    state: present
    comment: "Bot Example"
    ssh_public_key: "ssh-ed25519 ANzaC1yc2EA...KHgKLVcBaeKQ== bot@example.com"
    ssh_private_key: "{{ vault_bot_ssh_private_key }}"
    hosts: "{{ groups.all }}"
host_iam_users:
  - username: bobmeyer
    state: present
    groups: operator
    comment: "Bob Meyer"
    passwort: "{{ vault_iam_users_bobmeyer_password }}"
    hosts:
      - server1
```

And include it in your playbook.

```yml
- hosts: iam
  roles:
  - role: iam
```

## Docs

### Set password manually

Run `sudo passwd $USERNAME` to set the password.

### Add user to group manually

Run `sudo usermod -a -G sshusers scienceuli` to add a user to a group.

### Generate ssh key pair

Generate a ssh key pair for specified username.

```bash
SSH_USERNAME=bot
ssh-keygen -t ed25519 -C "$SSH_USERNAME" -f ./id_ed25519
echo "ssh_public_key: $(cat ./id_ed25519.pub)"
echo "vault_${SSH_USERNAME}_ssh_private_key: $(echo $(cat ./id_ed25519 | base64))"
```

### Generate vault entry for ssh private key

A private key must be base64 encoded.

```bash
VAULT_ID=scienceuli
SSH_USERNAME=bot
SSH_PRIVATE_KEY=$(echo "-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCe6OYs2gNexFN+ZUycULQMnpA7bsrcZID9EXWIvuCsRQAAAIhKCnlPSgp5
TwAAAAtzc2gtZWQyNTUxOQAAACCe6OYs2gNexFN+ZUycULQMnpA7bsrcZID9EXWIvuCsRQ
AAAEALWuJfaMs2PhuPWOisJ7Duxgw37DBVtN9fRNs1TQ8w/Z7o5izaA17EU35lTJxQtAye
kDtuytxkgP0RdYi+4KxFAAAAA2JvdAEC
-----END OPENSSH PRIVATE KEY-----" | base64 -b 0)

task encrypt-string "$VAULT_ID" "vault_${SSH_USERNAME}_ssh_private_key" "vault_${SSH_USERNAME}_ssh_private_key: $SSH_PRIVATE_KEY"
```
On Mac use `base64` with option `-b 0`.

## Troubleshooting

### Failed to set permissions

**Problem**

When running the iam task the following error is thrown:

```text
Failed to set permissions on the temporary files Ansible needs to create when becoming an unprivileged user (rc: 1, err: chmod: Ungültiger Modus: ‘A+user:username:rx:allow’
    „chmod --help“ liefert weitere Informationen.
For information on working around this, see https://docs.ansible.com/ansible-core/2.17/playbook_guide/playbooks_privilege_escalation.html#risks-of-becoming-an-unprivileged-user
```

**Solution**

Ensure the `acl` package is installed.

```bash
sudo apt install acl
```
