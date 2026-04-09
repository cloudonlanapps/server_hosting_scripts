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
