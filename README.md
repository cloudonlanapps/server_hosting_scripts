# FastAPI + PostgreSQL: Multi-Instance Docker Deployment

Have you ever built a FastAPI server backed by PostgreSQL, then realized you need to run
multiple instances of it — one for production, one for beta testing, maybe one more to
debug a feature branch — all on the same machine?

Setting that up by hand is tedious: separate databases, separate containers, port
management, nginx routing, SSL certificates, security hardening... it adds up fast.

These scripts handle all of that. You run one command to deploy, and each instance gets
its own PostgreSQL database, its own container, its own port, and its own data directory.
Add nginx and SSL with one more command. Done.

## How It Works

Each call to `deploy.sh` spins up **two Docker containers**:

1. **PostgreSQL** — a dedicated database instance for this deployment
2. **Server** — clones your repo from a specific git branch, installs dependencies, runs
   migrations, and starts uvicorn

```
                    ┌──────────────────────────────────────────────────┐
                    │                 Same Server                      │
                    │                                                  │
beta.example.com ───┼──► Nginx ──► :8001 ──► myproduct-main (server)  │
                    │                        myproduct-main (postgres) │
                    │                                                  │
www.example.com  ───┼──► Nginx ──► :8000 ──► myproduct-release (server)│
example.com      ───┤                        myproduct-release (postgres)│
                    └──────────────────────────────────────────────────┘
```

In **server mode**, the port is bound to `localhost` only — external traffic must go
through nginx. In **dev mode**, the port is exposed directly so you can hit it from
your browser or API client.

All deployment data (database files, uploads, static assets, config) is stored under
`~/.local/share/` in the deploying user's home directory. No root access required for
deployment, and everything is in one place for easy backup.

## What Your Server Needs to Follow

These scripts expect two entry points derived from your `--project` name:

| Convention | Example (--project myproduct) |
|---|---|
| **Server module** | `myproduct_server.main:app` — the uvicorn entry point |
| **Bootstrap command** | `myproduct_bootstrap` — a CLI command to seed the initial admin user |
| **Migrations** | `alembic upgrade head` — run automatically on every deploy/restart |
| **Dependency manager** | [uv](https://docs.astral.sh/uv/) with a `uv.lock` file |

Your repo should have a branch for each instance you want to run (e.g., `main` for beta,
`release` for production).

## Prerequisites

- **Docker** installed and running
- Current user in the **docker group** (to run Docker without sudo)
  ```bash
  # Check
  groups | grep docker
  # Fix
  sudo usermod -aG docker $USER && newgrp docker
  ```
- **git** (used inside the Docker build to clone your repo)
- For private repos: a GitHub token with read access

## Quick Start

### 1. Deploy

```bash
# Make scripts executable (one-time)
chmod +x *.sh

# Beta — deploy 'main' branch on port 8001 (default)
./deploy.sh --project myproduct \
  --git-url https://github.com/org/myproduct_server.git \
  --git-branch main \
  --bootstrap-password mybootstrappass \
  --postgres-password mydbpass \
  --allowed-websites beta.example.com

# Production — deploy 'release' branch on port 8000
./deploy.sh --project myproduct \
  --git-url https://github.com/org/myproduct_server.git \
  --git-branch release --port 8000 \
  --bootstrap-password mybootstrappass \
  --postgres-password mydbpass \
  --allowed-websites www.example.com,example.com
```

### 2. Connect Nginx (server mode only)

Server mode binds to localhost, so you need nginx to route external traffic:

```bash
sudo ./setup-nginx.sh --domain beta.example.com --port 8001
sudo ./setup-nginx.sh --domain www.example.com --port 8000
```

This configures nginx as a reverse proxy with SSL (via Let's Encrypt).

### 3. Harden Security

Review and adjust the security settings in `security.conf`, then apply:

```bash
# See what needs fixing
sudo ./audit-security.sh --domain beta.example.com:8001 --domain www.example.com:8000

# Apply firewall rules, rate limiting, and fail2ban
sudo ./setup-security.sh --domain beta.example.com:8001 --domain www.example.com:8000

# Verify everything is in place
sudo ./audit-security.sh --domain beta.example.com:8001 --domain www.example.com:8000
```

### 4. Development (local machine)

Dev mode exposes the port directly and allows all CORS origins — no nginx needed:

```bash
# Uses the repo's default branch
./deploy.sh --project myproduct \
  --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password mybootstrappass \
  --postgres-password mydbpass \
  --dev

# Or specify a branch for debugging
./deploy.sh --project myproduct \
  --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password mybootstrappass \
  --postgres-password mydbpass \
  --dev --git-branch fix/login-bug

curl http://localhost:8001/health
```


### Deploying a specific commit

`--git-branch` accepts a **branch, a tag, or a commit SHA** (full or short).
Omitted, it defaults to `main`.

```bash
./deploy.sh --project myproduct \
  --git-url https://github.com/org/myproduct_server.git \
  --git-branch 4b20e9e \
  --bootstrap-password <PASS> --postgres-password <PASS>
```

Branches and tags take a fast `--single-branch` clone. A commit SHA needs the
full history, so that path clones everything and then checks the commit out
detached — slower, but it is the only way `git` will resolve a bare SHA.


## Managing Deployments

```bash
# Restart (reads saved config, only needs secrets)
./restart.sh --project myproduct --git-branch main \
  --bootstrap-password mybootstrappass \
  --postgres-password mydbpass \
  --secret-key <your-saved-key>

# Stop
./stop.sh --project myproduct --git-branch main

# Stop dev
./stop.sh --project myproduct --dev

# Fresh database (wipes and recreates)
./deploy.sh ... --reset
```

## Optional: conf-driven wrappers

The raw scripts above take every secret and per-env setting on the command line.
That's flexible but verbose, and it pushes secret handling onto whoever invokes
them. Three optional wrappers move both concerns into one place:

- **`deploy-conf.sh <conf> <env>`** — wraps `deploy.sh`, reads secrets from
  [`pass`](https://www.passwordstore.org/), reads per-env settings from a conf file.
- **`restart-conf.sh <conf> <env>`** — wraps `restart.sh`, same conventions.
- **`stop-conf.sh <conf> <env>`** — wraps `stop.sh`. **No secrets needed**, so
  no `pass` dependency.

If you don't want `pass`, ignore these wrappers and call `deploy.sh`/`restart.sh`/
`stop.sh` directly. The wrappers are opt-in.

### Conf file

A bash-sourced file describing one project and its environments:

```bash
# myproduct.conf
PROJECT="myproduct"
GIT_URL="https://github.com/org/myproduct_server.git"

# Optional. Defaults to $PROJECT.
# PASS_PREFIX="myproduct"

ENVS=(prod beta dev)

prod_GIT_BRANCH="release"
prod_PORT="8000"
prod_ALLOWED_WEBSITES="www.example.com,example.com"

beta_GIT_BRANCH="main"
beta_PORT="8001"
beta_ALLOWED_WEBSITES="beta.example.com"

# dev: all settings optional. deploy.sh defaults port to 8001 and CORS to *.
# dev_GIT_BRANCH=""    # set to debug a specific branch; empty = repo default
# dev_PORT=""
# dev_ALLOWED_WEBSITES=""
```

The env name **`dev` is special**: when used, `--dev` is passed to the
underlying script and `<env>_GIT_BRANCH` / `<env>_PORT` / `<env>_ALLOWED_WEBSITES`
become optional. Any other env name is treated as server mode and requires all
three.

### Pass key layout

For each env, the wrappers expect these `pass` entries (under `$PASS_PREFIX`,
which defaults to `$PROJECT`):

| Key | Used by |
|---|---|
| `<prefix>/github-token` | `deploy-conf.sh` (shared across envs) |
| `<prefix>/<env>/bootstrap-password` | `deploy-conf.sh`, `restart-conf.sh` |
| `<prefix>/<env>/postgres-password` | `deploy-conf.sh`, `restart-conf.sh` |
| `<prefix>/<env>/secret-key` | `deploy-conf.sh`, `restart-conf.sh` |

Add them once with `pass insert <key>`. The wrappers pre-check all required
keys and print the exact `pass insert` commands for any that are missing.

### Example

```bash
./deploy-conf.sh  ./myproduct.conf prod    # build + start production
./restart-conf.sh ./myproduct.conf beta    # quick restart of beta (no rebuild)
./stop-conf.sh    ./myproduct.conf dev     # stop dev containers
```

A typical host repo just contains `myproduct.conf` plus a `justfile` (or
similar) that wires `just deploy <env>` / `just restart <env>` / `just stop <env>`
to these wrappers, with this repo added as a git submodule.

## Data Directory Layout

All data lives under `~/.local/share/` — no sudo required:

| Mode | Directory |
|---|---|
| Server (`--git-branch main`) | `~/.local/share/server_myproduct_main/` |
| Server (`--git-branch release`) | `~/.local/share/server_myproduct_release/` |
| Dev (no branch) | `~/.local/share/server_dev_myproduct/` |
| Dev (`--git-branch fix/bug`) | `~/.local/share/server_dev_myproduct_fix/bug/` |

Each directory contains:
```
db/           # PostgreSQL data files
uploads/      # User-uploaded files
static/       # Static assets
.deploy.env   # Saved deployment config (non-secret)
```

To back up everything: `cp -r ~/.local/share/server_*myproduct* /your/backup/path/`

## Script Reference

Every script supports `--help` for full usage details.

| Script | Purpose |
|---|---|
| `deploy.sh` | Build and deploy a new instance (or redeploy) |
| `restart.sh` | Restart an existing deployment with saved config |
| `stop.sh` | Stop containers without removing data |
| `deploy-conf.sh` | Optional: `deploy.sh` driven by a conf file + `pass` |
| `restart-conf.sh` | Optional: `restart.sh` driven by a conf file + `pass` |
| `stop-conf.sh` | Optional: `stop.sh` driven by a conf file (no `pass` needed) |
| `setup-nginx.sh` | Configure nginx reverse proxy with SSL for a domain |
| `audit-security.sh` | Check security settings against `security.conf` |
| `setup-security.sh` | Apply firewall, rate limiting, and fail2ban from `security.conf` |

## Troubleshooting

```bash
# View container logs
docker logs myproduct-main-server
docker logs myproduct-main-postgres

# Check environment variables
docker exec myproduct-main-server env | grep -E "CORS|ENVIRONMENT|PROJECT"

# Connect to the database
docker exec -it myproduct-main-postgres psql -U myproduct -d myproduct

# Test nginx config
sudo nginx -t
sudo tail -f /var/log/nginx/error.log

# Check SSL renewal
sudo certbot renew --dry-run
```
