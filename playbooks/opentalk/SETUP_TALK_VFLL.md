# talk.vfll.de – first setup

After the first successful deploy (README.md). Everything is done in Keycloak:
<https://accounts.talk.vfll.de/auth/admin/>

Two realms – don't mix them up (realm switcher top left):

| realm | for |
|---|---|
| **master** | Keycloak administrators only |
| **opentalk** | the people using talk.vfll.de |

Users of one realm don't exist in the other, so each account logs in at one place only:

- **master** users (admins) log in at the admin console `https://accounts.talk.vfll.de/auth/admin/`.
- **opentalk** users (meetings) log in at `https://talk.vfll.de`.

An admin who also joins meetings needs a second account in realm opentalk. Failed
logins show the reason in `docker logs opentalk-keycloak | grep LOGIN_ERROR`
(e.g. `user_not_found` = wrong realm or username).

## 1. Permanent admin account (master realm)

The deploy creates a **temporary** bootstrap admin (`admin`, password =
`vault_opentalk_keycloak_admin_password`):

```sh
ansible-vault view inventories/host_vars/lovelace_opentalk/vault.yml | grep keycloak_admin_password
```

1. Log in as `admin` (Keycloak shows a "temporary admin" warning).
2. Realm **master** → *Users* → *Add user*: username (e.g. `uli`), email, first/last
   name, *Email verified* on → *Create*.
3. *Credentials* → *Set password*, *Temporary* **off**.
4. *Role mapping* → *Assign role* → filter *Realm roles* → **admin** → *Assign*.
5. Optional, recommended: *Required user actions* → **Configure OTP** (2FA on first login).
6. Log out, log in as the new admin, then realm master → *Users* → `admin` → *Delete*.

Keycloak creates the bootstrap admin only when the master realm is first set up, so
it won't come back after a restart. The vault password is then unused. So create
the permanent admin **before** deleting `admin`. If you get locked out anyway, use
Keycloak's `kc.sh bootstrap-admin user` (see "Recovering the admin account" in the
Keycloak docs).

## 2. Realm opentalk: basics (once)

- *Realm settings* → *General*: display name is "VFLL OpenTalk" (from Ansible). Leave it.
- *Realm settings* → *Localization*: *Internationalization* on, supported locales
  `de`, `en`, default **de** (login pages in German).
- *Realm settings* → *Email*: SMTP server + sender (e.g. `noreply@vfll.de`), then
  *Test connection*. Without this, "Forgot password?" and invitation emails don't work.
- *Realm settings* → *Login*: *User registration* stays **off** (accounts only by
  admins); *Forgot password* on (needs SMTP); *Remember me* as you prefer.
- Brute-force protection and the password policy (8+ characters, not the username)
  come from the realm import. Tighten them under *Authentication* → *Policies* if you like.

## 3. User accounts (realm opentalk)

Realm **opentalk** → *Users* → *Add user*:

- **Username**, **Email**, **First / Last name**. The name is what others see in
  meetings. Tick *Email verified*.
- *Create* → *Credentials* → *Set password*, **Temporary on** (user must choose their
  own password at first login). With SMTP configured, you can instead send
  *Credential reset* → *Update password* as an email link.

New users get the default role `default-roles-opentalk` automatically. That's all
OpenTalk needs. They then log in at <https://talk.vfll.de>.

Disable/remove: user → *Enabled* off (keeps the account) or *Delete*.
Forgotten password: user → *Credentials* → *Reset password* (temporary).

**Guests** (external participants) don't need an account: the meeting organiser
shares the meeting's invite link.

## 4. Check

1. <https://talk.vfll.de> → log in with a test user → *Start new meeting*.
2. Join the same meeting from a second device (e.g. a phone on mobile data, not WLAN):
   audio/video both ways = LiveKit media ports (7881/tcp, 7882/udp) reachable.
3. Problems: `sudo docker logs --tail 50 opentalk-controller` / `opentalk-livekit` on lovelace.

## Notes

- Users and settings live in the Keycloak DB (`opentalk-keycloak-db`, nightly restic
  dump). They are **not** in Ansible: the realm file is imported only once.
- Email invitations to meetings from OpenTalk itself need the smtp-mailer service,
  which isn't deployed yet. Share the links by hand meanwhile.
