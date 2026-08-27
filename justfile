# Lifecycle recipes for a deployed server. Generic: nothing here names a
# product. The deployment supplies CONF and BACKUP_DIR, normally through the
# wrapper script its installer generated.
#
# First-run bootstrap is not here — that is the installer's job. These are the
# commands for a deployment that already exists.
#
# Run via the wrapper in the deployment directory:
#     ./ops deploy prod
# or directly:
#     just -f server_hosting_scripts/justfile CONF=/path/host.conf deploy prod

# Absolute path to the host conf. No default: a generic justfile cannot know
# which product it is serving, and guessing would be worse than failing.
CONF := env_var_or_default("CONF", "")

# Where restore looks for archives. Nothing here puts them there.
BACKUP_DIR := env_var_or_default("BACKUP_DIR", justfile_directory() / ".." / "backup")

scripts := justfile_directory()

default:
    @just --list

# Fail early and clearly when the wrapper did not pass CONF through.
_require-conf:
    #!/usr/bin/env bash
    if [ -z "{{ CONF }}" ] || [ ! -f "{{ CONF }}" ]; then
        echo "ERROR: CONF is unset or not a file: '{{ CONF }}'" >&2
        echo "       Run through the deployment's wrapper, or pass it:" >&2
        echo "         just -f {{ justfile_directory() }}/justfile CONF=/path/host.conf <recipe>" >&2
        exit 1
    fi

# ── Stack lifecycle ───────────────────────────────────────────────────────────

# Deploy <env>: rebuild the image and restart the stack.
deploy env="": _require-conf
    @if [ -z "{{env}}" ]; then just --list; else "{{scripts}}/deploy-conf.sh" "{{ CONF }}" "{{env}}"; fi

# Restart <env> reusing the saved deploy config (faster than deploy).
restart env="": _require-conf
    @if [ -z "{{env}}" ]; then just --list; else "{{scripts}}/restart-conf.sh" "{{ CONF }}" "{{env}}"; fi

# Stop <env>. No secrets needed.
stop env="": _require-conf
    @if [ -z "{{env}}" ]; then just --list; else "{{scripts}}/stop-conf.sh" "{{ CONF }}" "{{env}}"; fi

# DESTRUCTIVE, and single purpose — it neither backs up nor restores. Take a
# backup first.

# Blank <env>: stop the server, empty the database, clear uploads and static.
reset env="": _require-conf
    @if [ -z "{{env}}" ]; then just --list; else "{{scripts}}/reset-conf.sh" "{{ CONF }}" "{{env}}"; fi

# ── Restore ───────────────────────────────────────────────────────────────────
# Reads archives already sitting in BACKUP_DIR. Putting them there is out of
# scope by design: restore then needs no credentials for, and no network path
# to, wherever backups are kept.

# List the archives available locally.
restore-list: _require-conf
    @"{{scripts}}/restore-backup.sh" "{{ CONF }}" --list --backup-dir "{{ BACKUP_DIR }}"

# Restore <env> from an archive in BACKUP_DIR — newest, or a given stamp/path.
restore-backup env="" archive="": _require-conf
    @if [ -z "{{env}}" ]; then just --list; else "{{scripts}}/restore-backup.sh" "{{ CONF }}" "{{env}}" {{archive}} --backup-dir "{{ BACKUP_DIR }}"; fi

# Show what a restore would do, touching nothing.
restore-dry env="" archive="": _require-conf
    @if [ -z "{{env}}" ]; then just --list; else DRY_RUN=1 "{{scripts}}/restore-backup.sh" "{{ CONF }}" "{{env}}" {{archive}} --backup-dir "{{ BACKUP_DIR }}"; fi

# ── Secrets ───────────────────────────────────────────────────────────────────

# Not optional where media is encrypted at rest: uploads are ciphertext under a
# per-environment KEK held only in this store. A media backup without the key is
# unrecoverable noise, so treat the two as one backup.

# Back up the `pass` store AND the GPG key material needed to read it.
backup-pass: _require-conf
    @"{{scripts}}/backup-pass.sh" "{{ CONF }}"

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
