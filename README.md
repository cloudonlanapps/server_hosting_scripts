# server_hosting_scripts

Generic tooling for running a FastAPI + PostgreSQL server as a Docker stack.
Nothing here names a product. You write one installer per product; it fetches
this repo and generates a conf and a justfile.

## Prerequisites

- **Docker**, with the current user in the `docker` group:
  `groups | grep docker` — fix with `sudo usermod -aG docker $USER && newgrp docker`
- **git**, **just** (1.19+, for `import`), and **`pass`** with a working gpg-agent
- For a private server repo: a fine-grained PAT with **Contents: Read**

## What the server repo must provide

Derived from `PROJECT` (or `PACKAGE`, when they differ):

| | Example for `PROJECT="myproduct"` |
|---|---|
| uvicorn entry point | `myproduct_server.main:app` |
| bootstrap command | `myproduct_bootstrap` — seeds the initial admin |
| migrations | `alembic upgrade head`, run on every deploy |
| dependencies | [uv](https://docs.astral.sh/uv/) with a committed `uv.lock` |

One branch per deployed environment, e.g. `release` for prod, `beta_release`
for beta.

---

## How to write an installer for a new product

An installer is one shipped file. It writes a conf, fetches this repo at a
chosen ref, and generates its justfile.

**1. Choose values that do not collide with existing deployments:** a
`PROJECT` name, a `PASS_PREFIX`, and one port per environment.

**2. Write the conf your installer will emit.** Required:

```bash
PROJECT="myproduct"
GIT_URL="https://github.com/<org>/<server-repo>.git"
STACK_PREFIX="myprefix"              # names containers and the data dir by env
PASS_PREFIX="secrets/myproduct"      # defaults to $PROJECT

ENVS=(prod beta dev)

prod_GIT_BRANCH="release"     ; prod_PORT="9001" ; prod_ALLOWED_WEBSITES="example.com,www.example.com"
beta_GIT_BRANCH="beta_release"; beta_PORT="9002" ; beta_ALLOWED_WEBSITES="beta.example.com"
dev_GIT_BRANCH="main"         ; dev_PORT="8001"
```

`prod` and `beta` must name a branch. A commit SHA is rejected for anything but
`dev`.

**3. Add whatever the server needs in its environment**, as
`<env>_EXTRA_ENV` entries. A value starting with `@` is read from `pass`;
anything else is a literal. Only variable *names* are written to disk.

The `@` is also the routing rule. A literal is passed to the container as an
environment variable. A `pass`-sourced value is mounted as a **Docker secret** —
a tmpfs file at `/run/secrets/<lowercased name>` — so it appears in neither
`docker inspect`, `/proc/<pid>/environ`, nor the compose config dump, all of
which are readable by anyone in the `docker` group. The application picks these
up by pointing `pydantic-settings` at `secrets_dir="/run/secrets"`, which
matches a file to a settings field by name.

The same applies to the values this tooling supplies itself: the database URL,
the secret key, the bootstrap password and the postgres password are all
mounted rather than exported. Postgres reads its own via `POSTGRES_PASSWORD_FILE`.
Where a secret file is absent the environment is still honoured, so a
deployment can move one value at a time.

```bash
_IDENTITY_ENV=(
    "CLUB_NAME=Example Club"
    "API_BASE_URL=https://api.example.com"
)
_PROD_SECRETS=("ENCRYPTION_KEY=@secrets/myproduct/prod/encryption_key")

prod_EXTRA_ENV=("${_IDENTITY_ENV[@]}" "${_PROD_SECRETS[@]}")
```

**4. Optionally override nginx tuning** — read by `setup-nginx.sh`, taking
precedence over `security.conf`:

```bash
NGINX_CLIENT_MAX_BODY_SIZE="60M"     # must exceed the server's upload limit
```

**5. Have the installer fetch this repo and write the deployment justfile.**
It exports this deployment's paths and imports the generic recipes, so `just`
runs from the deployment directory with nothing in between:

```bash
git clone "$HOSTING_SCRIPTS_URL" "$DIR/server_hosting_scripts"
git -C "$DIR/server_hosting_scripts" checkout "$HOSTING_SCRIPTS_REF"

cat > "$DIR/justfile" <<EOF
export CONF := justfile_directory() / "<conf-name>.conf"
export BACKUP_DIR := justfile_directory() / "backup"

import 'server_hosting_scripts/justfile'
EOF
```

Export rather than declare: `just` rejects a variable defined in both the
importing and the imported file.

Clone then checkout — `git clone --branch` rejects a raw commit, so pinning
would fail.

**6. Copy `project_README_template.md`** into the product's folder as its
README and replace the placeholders. Keep the prose — every product's README
should differ only in its values table, so a reader can move between products
without re-reading, and so one product's instructions cannot be corrected while
another's rot.

**7. Required secrets in `pass`**, under `$PASS_PREFIX`:

```
github-token                          (private server repos only)
<env>/bootstrap-password
<env>/postgres-password
<env>/secret-key
```

Missing ones are listed by name on the first deploy.

---

## Commands once deployed

Run `just` from the deployment directory. `<env>` is any name in `ENVS`.

```bash
just --list                # every recipe
just deploy <env>          # rebuild the image and restart the stack
just restart <env>         # restart using the saved config
just stop <env>            # stop the stack
just reset <env>           # DESTRUCTIVE: empty the database, clear uploads and static
just backup-pass           # back up the pass store and its GPG key material
```

### Restore

Reads `backup/` in the deployment directory and nothing else — it never
contacts a backup host, so it needs no credentials for one. Putting an archive
there is a separate job.

```
backup/<project>-<stamp>.tar.gz    database archive
backup/files/static/               static content
backup/files/uploads/              uploaded media
```

```bash
just restore-list                  # what is available locally
just restore-dry <env>             # resolve everything, touch nothing
just restore-backup <env>          # newest archive
just restore-backup <env> <stamp>  # a specific one
```

Restore refuses when the archive's alembic revision does not match the running
code. Deploy the matching code rather than overriding.

Where media is encrypted at rest, `uploads/` is ciphertext under the **source**
environment's key. The target environment's `encryption_key` must be a copy of
it, or the restored media will not decrypt.

### nginx and TLS

Run once per public environment, as root. It generates the vhost and requests a
certificate; there is no re-install recipe, because certbot rewrites the vhost
in place and a second run would drop a live site to plain HTTP. To redo it,
remove the file under `/etc/nginx/sites-available/` first, or pass `--force`.

```bash
sudo ./setup-nginx.sh --domain <domain> --port <port> --conf <conf-file>
sudo ./setup-security.sh --domain <domain>:<port>      # ufw, fail2ban, rate limits
sudo ./audit-security.sh --domain <domain>:<port>      # check without changing
```

### Not wired into the justfile

`backup-conf.sh`, `restore-conf.sh` and `verify-conf.sh` implement only the
branch-based container naming and ignore `STACK_PREFIX`, so on a deployment
that sets it they resolve names that do not exist. Call them directly only if
your conf omits `STACK_PREFIX`.
