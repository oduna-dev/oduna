# Restore drill

The drill proves the central promise: rebuild an instance from Git on other
hardware (a spare machine or a VM with the disk layout of the host), restore the
data from the offsite backup and log in through SSO. This page is the procedure
and the list of what is known to need care. Sections marked **unverified** have
not been run end to end yet; the first drill confirms or corrects them, and
every correction belongs back into this page.

## Pass criteria

- `checks.sh` passes on the rebuilt host (with `CHECK_BACKUPS=1` once a nightly
  run has happened).
- A member logs in to every app through the IdP.
- Known data is back: a Vaultwarden item and its attachment, an Actual Budget
  budget, a Forgejo repository with its history, an Immich photo with its
  metadata, the identity provider's users.
- The offsite job runs again against the same repository.

## What has to exist outside the box

| Item                              | Where it lives                             |
| --------------------------------- | ------------------------------------------ |
| Instance repository (Git)         | an external copy, never only the box       |
| Workstation age key (`&admin`)    | the operator's key store, not in the repo  |
| Pre-seed file                     | workstation-local, rebuilt from the vault  |
| Borg passphrase                   | `secrets/secrets.yaml` (`borg_passphrase`) |
| Borg SSH key and StorageBox login | recovery vault (escrow) and pre-seed       |
| Host key and pool keys of the old | recovery vault; not needed for a rebuild   |

## What the offsite backup holds

The Borg job (`modules/backups.nix`) backs up the local backup root with the
nightly dumps, plus every enabled app's declared paths and the instance's
`homelab.backup.paths`:

| App         | Content                                                      |
| ----------- | ------------------------------------------------------------ |
| Vaultwarden | SQLite dump, attachments, Send files, RSA key                |
| Actual      | `account.sqlite` dump and the budget files in `user-files`   |
| Forgejo     | `forgejo dump` archive (repositories, data, database)        |
| Immich      | `pg_dumpall` dump and the photo library (without thumbnails) |
| Authentik   | custom-format `pg_dump`                                      |
| Navidrome   | the music library; its database is rebuilt by a rescan       |

Not backed up and rebuilt instead: IdP objects (converge recreates the
applications, providers and the outpost), the Beszel agent key (derived from the
hub identity) and the Forgejo runner registration (postinstall registers it
again).

## 0. Seed known data (unverified)

The box starts empty, so seed data before the backup that the drill restores:

```sh
scripts/drill-data.sh seed <host> root@<ip>     # from the instance directory
```

This creates a Forgejo repository with two commits and uploads one photo to
Immich, through the apps' APIs with the shared admin identity. The manifest
(repository head, photo id and hash) is saved as `.drill-manifest.json` in the
instance directory, outside the box and the backup. After the restore:

```sh
scripts/drill-data.sh verify <host> root@<new-ip>
```

A Vaultwarden item with an attachment and an Actual Budget budget have to be
created by hand in the apps (their data is encrypted or synced by the client)
and checked by eye after the restore.

## 1. Reinstall

Run `bootstrap.sh <host> root@<ip>` from the instance directory with the
pre-seed file in place. It generates a new host key, a new Borg key and new ZFS
pool keys, re-keys the existing `secrets/secrets.yaml` to the new host key and
installs the system. Store the escrow it prints.

Postinstall installs the new Borg public key on the StorageBox only while the
host config has no `storageBoxRepo`. On a rebuild the URL exists already, so
authorise the key by hand (**unverified** on a real StorageBox). The StorageBox
only accepts this with its password, which ssh asks for on the terminal
(postinstall passes it through `sshpass`):

```sh
ssh root@<ip> cat /etc/ssh/borg_append_only_key.pub \
  | ssh -p 23 <storagebox-user>@<storagebox-user>.your-storagebox.de install-ssh-key
```

## 2. Fetch the data from Borg (unverified)

On the new host, as root, stop the stacks and services first so nothing writes
while files come back:

```sh
systemctl stop vaultwarden actual forgejo immich-stack authentik-stack
export BORG_PASSCOMMAND='cat /run/secrets/borg_passphrase'
export BORG_RSH='ssh -i /etc/ssh/borg_append_only_key -p 23'
repo=<the storageBoxRepo URL of the host config>
borg list "$repo"
cd / && borg extract --dry-run --list "$repo::<archive>"   # inspect first
cd / && borg extract "$repo::<archive>"
```

Archive paths are absolute without the leading slash, so extracting from `/`
puts files back where they were. Check ownership afterwards: Vaultwarden files
belong to `vaultwarden`, Actual files to `actual`.

## 3. Restore the dumps (unverified)

The dumps are in `<bulkPath>/backups/<app>/`. Per app:

- **Vaultwarden:** copy the SQLite dump over `<appdata>/vaultwarden/db.sqlite3`,
  remove stale `db.sqlite3-wal` and `-shm`, `chown vaultwarden:vaultwarden`.
- **Actual:** copy the dump over
  `<appdata>/actual-budget/server-files/account.sqlite`, `chown actual:actual`.
- **Immich:** start `immich-stack` with the server stopped
  (`docker stop immich_server`), then restore the dump, which drops and
  recreates objects (`pg_dumpall -c --if-exists`):

  ```sh
  gunzip -c immich_db_<date>.sql.gz \
    | docker exec -i immich_postgres psql -U postgres
  ```

- **Authentik:** start `authentik-stack`, stop `authentik_server` and
  `authentik_worker`, restore, then start them again:

  ```sh
  docker exec -i authentik_postgres pg_restore --clean --if-exists \
    -U authentik -d authentik < authentik_db_<date>.dump
  ```

- **Forgejo:** the archive from `forgejo dump` holds the repositories, the data
  directory and the database (an SQL file for SQLite). Unpack it, put the
  repositories and data back under `<appdata>/forgejo`, import the SQL into the
  SQLite database, `chown -R forgejo:forgejo`. The exact layout is the first
  thing the drill has to confirm.

Then start everything: `systemctl start vaultwarden actual forgejo` and the
stacks.

## 4. Converge and verify

```sh
systemctl restart homelab-converge.service
journalctl -u homelab-converge.service --no-pager | tail -50
CHECK_BACKUPS=1 checks.sh <host> root@<ip>
```

Converge recreates what is not in the backup (see above) and reconciles the
break-glass admins with the shared password. Then walk the pass criteria and log
in to every app through the IdP.

## Known gaps

- There is no restore tooling; sections 2 and 3 are manual. The first drill
  decides which of them become a script driven by the backup manifest.
- The Borg job reads live files for the app paths (Actual budget files,
  Vaultwarden attachments). A snapshot-based read would make them consistent.
- A reinstall always creates new identities. Reusing the escrowed Borg key would
  avoid the manual authorisation in step 1.
