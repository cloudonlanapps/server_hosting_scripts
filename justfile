# Lifecycle recipes for a deployed server. Generic: nothing here names a
# product. The deployment supplies CONF and BACKUP_DIR by exporting them.

#
# First-run bootstrap is not here — that is the installer's job. These are the
# commands for a deployment that already exists.
#
# Not run directly. A deployment's justfile imports this one and exports the
# two values it needs:
#
#     export CONF := justfile_directory() / "host_<product>.conf"
#     export BACKUP_DIR := justfile_directory() / "backup"
#     import 'server_hosting_scripts/justfile'
#
# Then `just deploy prod` works from the deployment directory. CONF and
# BACKUP_DIR are read from the environment rather than declared here, because
# `just` rejects a variable defined in both the importing and imported file.
#
# source_directory() rather than justfile_directory(): under an import the
# latter resolves to the importing file's directory, which would send every
# recipe looking for these scripts in the wrong place.
scripts := source_directory()

default:
    @just --list

# Fail early and clearly when the importing justfile did not export CONF.
_require-conf:
    #!/usr/bin/env bash
    if [ -z "${CONF:-}" ] || [ ! -f "${CONF:-}" ]; then
        echo "ERROR: CONF is unset or not a file: '${CONF:-}'" >&2
        echo "       Run from a deployment directory whose justfile imports this one," >&2
        echo "       or set it: CONF=/path/host.conf just -f {{ scripts }}/justfile <recipe>" >&2
        exit 1
    fi

# ── Stack lifecycle ───────────────────────────────────────────────────────────

# Deploy <env>: rebuild the image and restart the stack.
deploy env="": _require-conf
    @if [ -z "{{env}}" ]; then just --list; else "{{scripts}}/deploy-conf.sh" "$CONF" "{{env}}"; fi

# Restart <env> reusing the saved deploy config (faster than deploy).
restart env="": _require-conf
    @if [ -z "{{env}}" ]; then just --list; else "{{scripts}}/restart-conf.sh" "$CONF" "{{env}}"; fi

# Stop <env>. No secrets needed.
stop env="": _require-conf
    @if [ -z "{{env}}" ]; then just --list; else "{{scripts}}/stop-conf.sh" "$CONF" "{{env}}"; fi

# DESTRUCTIVE, and single purpose — it neither backs up nor restores. Take a
# backup first.

# Blank <env>: stop the server, empty the database, clear uploads and static.
reset env="": _require-conf
    @if [ -z "{{env}}" ]; then just --list; else "{{scripts}}/reset-conf.sh" "$CONF" "{{env}}"; fi

# ── Restore ───────────────────────────────────────────────────────────────────
# Reads archives already sitting in BACKUP_DIR. Putting them there is out of
# scope by design: restore then needs no credentials for, and no network path
# to, wherever backups are kept.

# List the archives available locally.
restore-list: _require-conf
    @"{{scripts}}/restore-backup.sh" "$CONF" --list --backup-dir "$BACKUP_DIR"

# Restore <env> from an archive in BACKUP_DIR — newest, or a given stamp/path.
restore-backup env="" archive="": _require-conf
    @if [ -z "{{env}}" ]; then just --list; else "{{scripts}}/restore-backup.sh" "$CONF" "{{env}}" {{archive}} --backup-dir "$BACKUP_DIR"; fi

# Show what a restore would do, touching nothing.
restore-dry env="" archive="": _require-conf
    @if [ -z "{{env}}" ]; then just --list; else DRY_RUN=1 "{{scripts}}/restore-backup.sh" "$CONF" "{{env}}" {{archive}} --backup-dir "$BACKUP_DIR"; fi

# ── Secrets ───────────────────────────────────────────────────────────────────

# Not optional where media is encrypted at rest: uploads are ciphertext under a
# per-environment KEK held only in this store. A media backup without the key is
# unrecoverable noise, so treat the two as one backup.

# Back up the `pass` store AND the GPG key material needed to read it.
backup-pass: _require-conf
    @"{{scripts}}/backup-pass.sh" "$CONF"

# ── Notes ─────────────────────────────────────────────────────────────────────
#
# backup-conf.sh, restore-conf.sh and verify-conf.sh are deliberately NOT wired
# in. They derive container names from the branch scheme only and ignore
# STACK_PREFIX, so on a deployment that sets it they resolve names that do not
# exist. They remain in the repo for the push-model deployments they were
# written for.
#
# nginx is configured once, by the installer, via setup-nginx.sh. There is no
# recipe to re-install it: the vhost is generated and then rewritten in place by
# certbot, so a second install would drop a live site back to plain HTTP.
