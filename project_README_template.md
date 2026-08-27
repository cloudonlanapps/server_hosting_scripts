# Deploy the <Product Name> server

<!--
  Template for a product's deploy README. Copy into the product folder beside
  its installer, then replace every placeholder:

    <project>        short slug, e.g. ihm — also names the script, conf and folder
    <Product Name>   full display name shown in the heading
    <pass-prefix>    where this product's secrets live, e.g. secrets/<project>
    <server-repo>    org/repo of the application this deploys
    <prod-port> <beta-port> <dev-port>
    <domains>        the hostnames this product serves

  Keep the prose as it is. Every product's README should differ only in the
  values table and, while a product is still being set up, the note in step 3.
  Identical wording is what lets a reader move between products without
  re-reading, and stops one product's instructions being corrected while
  another's rot.
-->

| | |
|---|---|
| Installer | `deploy_<project>_server.sh` |
| Conf written | `host_<project>_server.conf` |
| Secrets in `pass` | `<pass-prefix>` |
| Ports | prod `<prod-port>` · beta `<beta-port>` · dev `<dev-port>` |
| Domains | <domains> |

Run everything on the target machine, as the user who owns the `pass` store.
Not over a non-interactive SSH command — gpg cannot prompt for the passphrase
without a terminal.

## 1. Check the secrets exist

```bash
pass ls <pass-prefix>
```

Required, per environment:

```
<pass-prefix>/github-token
<pass-prefix>/<env>/bootstrap-password
<pass-prefix>/<env>/postgres-password
<pass-prefix>/<env>/secret-key
<pass-prefix>/<env>/encryption_key
```

`github-token` is a fine-grained PAT with **Contents: Read** on
`<server-repo>`. Nothing needs write access. Anything missing is listed by name
on the first deploy.

## 2. Install

```bash
./deploy_<project>_server.sh --dir ~/<project>
```

| Option | |
|---|---|
| `--dir DIR` | where the deployment lives |
| `--hosting-ref REF` | pin the tooling to a branch, tag or commit (default `main`) |
| `--server-ref COMMIT` | build **dev** from a commit instead of `main` |
| `--no-install` | refresh the conf and wrapper without re-fetching the tooling |

Re-running is safe: it never overwrites an existing conf and never touches
`backup/`.

## 3. Review the conf

```bash
$EDITOR ~/<project>/host_<project>_server.conf
```

Every identity value must be set. The server has no product-specific defaults,
so it refuses to start rather than serving under the wrong name.

<!-- While a product is still being set up, add here:
This conf ships with `REPLACE_ME` in <n> fields; fill every one before the
first deploy. Email is commented out until a sending domain is verified with
the provider — until then the server logs mail instead of sending it.
Delete this note once the values are in. -->

## 4. Deploy an environment

```bash
cd ~/<project>
./ops deploy dev          # or beta, or prod
```

## 5. Configure nginx — public environments only, once

```bash
sudo ./deploy_<project>_server.sh --dir ~/<project> --install-ngx prod
```

Generates the vhost and requests a certificate. Skip it for dev. There is no
re-install: certbot rewrites the vhost in place, so a second run would drop a
live site to plain HTTP.

## Day-to-day: `./ops`

Run from `~/<project>`. `<env>` is `prod`, `beta` or `dev`.

```bash
./ops --list                # every recipe
./ops deploy <env>          # rebuild the image and restart
./ops restart <env>         # restart without rebuilding
./ops stop <env>            # stop the stack
./ops reset <env>           # DESTRUCTIVE: empty the database, clear uploads and static
./ops backup-pass           # back up the pass store and its GPG key material
```

## Restore a backup

Restore reads `~/<project>/backup/` and nothing else. It never contacts a backup
host, so it needs no credentials for one — copying an archive across is a
separate job.

```
backup/<project>-<stamp>.tar.gz    database archive
backup/files/static/               static content
backup/files/uploads/              uploaded media
```

```bash
cd ~/<project>
./ops restore-list                  # what is available locally
./ops restore-dry <env>             # resolve everything, touch nothing
./ops restore-backup <env>          # newest archive
./ops restore-backup <env> <stamp>  # a specific one
```

Restore refuses when the archive's schema revision does not match the running
code. Deploy the matching code rather than overriding.

Restored `uploads/` is ciphertext under the **source** environment's key. To
load one environment's data into another, the target's `encryption_key` in
`pass` must be a copy of the source's, or the media will not decrypt.
