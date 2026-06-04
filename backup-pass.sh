#!/bin/bash
set -euo pipefail

# Usage: ./backup-pass.sh [<conf-file>]
#
# Point-in-time backup of the host's `pass` (password-store) secrets AND the
# GPG key material needed to decrypt them, so the store is fully recoverable on
# a clean machine. Companion to backup-conf.sh, same LOCAL/REMOTE idioms.
#
# What it captures (the encrypted store on its own is useless without the key):
#   - the password-store directory VERBATIM (rsync -a; the .gpg files are
#     already encrypted, and .gpg-id / any .git history come along),
#   - the GPG public + SECRET key(s) named by the store's .gpg-id, plus
#     ownertrust — restore these and `pass` works again on a fresh box,
#   - a names-only tree (no secret values) for human reference.
#
# PLAINTEXT=1 additionally decrypts every entry into one file for an OFFLINE
# PAPER backup. Off by default: it writes cleartext secrets to disk. Treat that
# file — and gpg-secret.asc — as crown jewels.
#
# The <conf-file> argument is OPTIONAL and only used to name the backup root
# (PROJECT) and to supply SSH defaults in REMOTE mode; pass it for parity with
# backup-conf.sh (`just backup-pass`).
#
# LOCAL vs REMOTE  (mirrors backup-conf.sh)
#   Default: back up THIS machine's store.
#   REMOTE=1: pull the store + export the keys from a remote host over SSH,
#   landing the artifacts LOCALLY (off-site pull). SSH details default to the
#   conf's SSH_USER / SSH_HOST / SSH_PORT; override with
#   BACKUP_SSH_USER / _HOST / _PORT.
#
# Store location defaults to ~/.password-store; override the relative path with
# PASS_STORE_REL=... (relative to the target user's $HOME).
#
# Output (override the root with BACKUP_ROOT=...):
#   ${BACKUP_ROOT:-$HOME/<project>_backups}/<project>-pass/<UTC-timestamp>/
#     ├── password-store/    verbatim copy of the encrypted store (.gpg-id, .git)
#     ├── gpg-public.asc      exported public key(s) for the store's gpg-id(s)
#     ├── gpg-secret.asc      exported SECRET key(s) — the decryptor (chmod 600)
#     ├── gpg-ownertrust.txt  exported ownertrust
#     ├── pass-tree.txt       entry names only (NO values)
#     ├── pass-plaintext.txt  cleartext dump (only if PLAINTEXT=1; chmod 600)
#     └── MANIFEST.txt        what/when/where + key ids + counts + sizes

# Secrets land in this backup; keep every file owner-only from creation.
umask 077

CONF_FILE="${1:-}"
if [ -n "$CONF_FILE" ]; then
    if [ ! -f "$CONF_FILE" ]; then echo "ERROR: Conf file not found: $CONF_FILE"; exit 1; fi
    # shellcheck disable=SC1090
    source "$CONF_FILE"
fi
PROJECT="${PROJECT:-pass}"            # 'ihm' from the conf, else a bare 'pass'
STORE_REL="${PASS_STORE_REL:-.password-store}"

# --- Where do pass/gpg/rsync run: locally or over SSH? (as in backup-conf.sh) -
REMOTE_MODE=0
SSH_DESC="local"
if [ -n "${REMOTE:-}" ]; then
    REMOTE_MODE=1
    R_HOST="${REMOTE_SSH_HOST:-${BACKUP_SSH_HOST:-${SSH_HOST:-}}}"
    R_USER="${REMOTE_SSH_USER:-${BACKUP_SSH_USER:-${SSH_USER:-}}}"
    R_PORT="${REMOTE_SSH_PORT:-${BACKUP_SSH_PORT:-${SSH_PORT:-22}}}"
    if [ -z "$R_HOST" ]; then echo "ERROR: REMOTE=1 but no SSH host (set SSH_HOST or BACKUP_SSH_HOST)."; exit 1; fi
    SSH_TGT="${R_USER:+$R_USER@}$R_HOST"
    SSH_DESC="${SSH_TGT} (port ${R_PORT})"
fi

# runc <cmd>: run where the store lives (local shell or remote via SSH).
runc() {
    if [ "$REMOTE_MODE" = 1 ]; then ssh -p "$R_PORT" -o BatchMode=yes "$SSH_TGT" "$1"
    else bash -c "$1"; fi
}

# --- Preconditions (checked on the target) ---
if [ "$REMOTE_MODE" = 1 ]; then
    ssh -p "$R_PORT" -o BatchMode=yes "$SSH_TGT" true 2>/dev/null \
        || { echo "ERROR: cannot SSH to $SSH_DESC (need key-based access)."; exit 1; }
fi
runc "command -v pass >/dev/null" || { echo "ERROR: pass not found on $SSH_DESC."; exit 1; }
runc "command -v gpg  >/dev/null" || { echo "ERROR: gpg not found on $SSH_DESC."; exit 1; }
runc "test -d \"\$HOME/${STORE_REL}\"" || { echo "ERROR: store not found on $SSH_DESC: \$HOME/${STORE_REL}"; exit 1; }
runc "test -f \"\$HOME/${STORE_REL}/.gpg-id\"" || { echo "ERROR: no .gpg-id in store on $SSH_DESC (is this a pass store?)"; exit 1; }
command -v rsync >/dev/null || { echo "ERROR: rsync not found locally."; exit 1; }

# Key id(s) this store is encrypted to — exported so the store is recoverable.
GPG_IDS="$(runc "tr '\n' ' ' < \"\$HOME/${STORE_REL}/.gpg-id\"")"
GPG_IDS="$(echo "$GPG_IDS" | xargs)"   # trim
if [ -z "$GPG_IDS" ]; then echo "ERROR: .gpg-id is empty on $SSH_DESC."; exit 1; fi

# --- Backup destination (timestamped, LOCAL, outside the repo) ---
TS="$(date -u +%Y%m%d_%H%M%SZ)"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/${PROJECT}_backups}"
BK="${BACKUP_ROOT}/${PROJECT}-pass/${TS}"
mkdir -p "$BK"

echo "==> Backing up pass store for '${PROJECT}' from ${SSH_DESC}"
echo "    Store:       \$HOME/${STORE_REL}   gpg-id: ${GPG_IDS}"
echo "    Destination: $BK  (local)"

# --- 1. Encrypted store, verbatim ---
echo "==> Copying password-store (verbatim, encrypted)..."
mkdir -p "$BK/password-store"
if [ "$REMOTE_MODE" = 1 ]; then
    rsync -a -e "ssh -p $R_PORT -o BatchMode=yes" "$SSH_TGT:${STORE_REL}/" "$BK/password-store/"
else
    rsync -a "$HOME/${STORE_REL}/" "$BK/password-store/"
fi

# --- 2. GPG key material (public + ownertrust always; secret best-effort) ---
echo "==> Exporting GPG public key(s) + ownertrust..."
runc "gpg --armor --export ${GPG_IDS}" >"$BK/gpg-public.asc"
runc "gpg --export-ownertrust" >"$BK/gpg-ownertrust.txt" 2>/dev/null || true

echo "==> Exporting GPG secret key(s) (the decryptor)..."
SECRET_OK=0
if runc "gpg --batch --armor --export-secret-keys ${GPG_IDS}" >"$BK/gpg-secret.asc" 2>/dev/null \
        && [ -s "$BK/gpg-secret.asc" ]; then
    chmod 600 "$BK/gpg-secret.asc"
    SECRET_OK=1
else
    rm -f "$BK/gpg-secret.asc"
    echo "    WARNING: could not export the secret key non-interactively (passphrase/agent)."
    echo "             Run this once, by hand, into the backup dir:"
    echo "               gpg --export-secret-keys --armor ${GPG_IDS} > '$BK/gpg-secret.asc'"
fi

# --- 3. Names-only tree (no secret values) ---
echo "==> Writing entry tree (names only)..."
runc "cd \"\$HOME/${STORE_REL}\" && find . -name '*.gpg' | sed 's#^\\./##; s#\\.gpg\$##' | sort" \
    >"$BK/pass-tree.txt"
ENTRY_COUNT="$(grep -c . "$BK/pass-tree.txt" || true)"

# --- 4. Optional cleartext dump (paper backup) ---
PLAINTEXT_NOTE="(skipped; set PLAINTEXT=1 for a paper backup)"
if [ -n "${PLAINTEXT:-}" ]; then
    echo "==> Decrypting every entry into pass-plaintext.txt (PLAINTEXT=1)..."
    runc "cd \"\$HOME/${STORE_REL}\" && PASSWORD_STORE_DIR=\"\$HOME/${STORE_REL}\"; \
          find . -name '*.gpg' | sed 's#^\\./##; s#\\.gpg\$##' | sort | \
          while read -r n; do printf '\n=== %s ===\n' \"\$n\"; pass show \"\$n\"; done" \
        >"$BK/pass-plaintext.txt"
    chmod 600 "$BK/pass-plaintext.txt"
    PLAINTEXT_NOTE="present (chmod 600) — CLEARTEXT secrets; print + shred, do not keep on disk"
fi

# --- 5. Manifest ---
STORE_SIZE="$(du -sh "$BK/password-store" | cut -f1)"
cat >"$BK/MANIFEST.txt" <<EOF
project:          $PROJECT
kind:             pass (password-store) + gpg key material
source_host:      $SSH_DESC
store:            \$HOME/${STORE_REL}
gpg_id(s):        $GPG_IDS
created_utc:      $TS
password-store/:  $STORE_SIZE (verbatim, encrypted), ${ENTRY_COUNT} entries
gpg-public.asc:   exported public key(s)
gpg-secret.asc:   $([ "$SECRET_OK" = 1 ] && echo 'exported (chmod 600)' || echo 'NOT exported — see warning above')
gpg-ownertrust.txt: exported
pass-tree.txt:    ${ENTRY_COUNT} entry names (no values)
pass-plaintext.txt: $PLAINTEXT_NOTE
EOF

chmod -R go-rwx "$BK" 2>/dev/null || true

echo "==> Done."
echo "    entries: $ENTRY_COUNT   store: $STORE_SIZE   secret-key: $([ "$SECRET_OK" = 1 ] && echo exported || echo MISSING)"
echo "    -> $BK"
if [ "$SECRET_OK" != 1 ]; then
    echo "    NOTE: without gpg-secret.asc this backup CANNOT be decrypted — export it manually (above)."
fi
