# FastAPI Server Docker Deployment

Deploy any FastAPI server using Docker with nginx reverse proxy and HTTPS. Supports multiple environments (beta, production, development) on the same server.

## Naming Convention

Given `--project myproduct`, all names are derived automatically:

| Component | Pattern | Example |
|-----------|---------|---------|
| Server entry point | `<project>_server.main:app` | `myproduct_server.main:app` |
| Bootstrap command | `<project>_bootstrap` | `myproduct_bootstrap` |
| DB name & user | `<project>` | `myproduct` |
| Data dir (prod) | `/var/lib/<project>-server` | `/var/lib/myproduct-server` |
| Data dir (beta) | `/var/lib/<project>-server-beta` | `/var/lib/myproduct-server-beta` |
| Data dir (dev) | `./data-<project>` | `./data-myproduct` |
| Containers | `<project>-<env>-server` | `myproduct-prod-server` |

## Architecture

```
                      ┌─────────────────────────────────────────┐
                      │             Same Linux VPS              │
                      │                                         │
beta.domain.com ──────┼──► Nginx ──► :8001 ──► <project>-beta  │
                      │                                         │
www.domain.com  ──────┼──► Nginx ──► :8000 ──► <project>-prod  │
domain.com      ──────┤                                         │
                      └─────────────────────────────────────────┘
```

## Environments

| Environment | Port | Data Directory | Git Branch | Default |
|-------------|------|----------------|------------|---------|
| **beta** | 8001 | `/var/lib/<project>-server-beta` | `main` | yes (safe) |
| **prod** | 8000 | `/var/lib/<project>-server` | `release` | |
| **dev** | 8000 | `./data-<project>` | `main` | |

**Safety:** Scripts default to beta to prevent accidental production updates.

## Quick Start

### macOS Development

```bash
chmod +x *.sh

./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password mybootstrappass --postgres-password mydbpass --dev

curl http://localhost:8000/health
```

### Linux Server - Beta Environment

```bash
./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password mybootstrappass --postgres-password mydbpass \
  --allowed-websites beta.example.com

sudo ./setup-nginx.sh --domain member.example.com --port 8001

curl https://member.example.com/health
```

### Linux Server - Production Environment

```bash
./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password mybootstrappass --postgres-password mydbpass \
  --allowed-websites www.example.com,example.com --prod

sudo ./setup-nginx.sh --domain api.example.com --port 8000
sudo ./setup-security.sh --domain api.example.com --domain member.example.com

curl https://api.example.com/health
```

## Command Reference

### deploy.sh

```
./deploy.sh --project NAME --git-url URL --bootstrap-password PASS --postgres-password PASS [options]
```

Run `./deploy.sh --help` for full options.

### restart.sh

Reads non-secret config (port, data-dir, allowed-websites) from `.deploy.env` saved by `deploy.sh`.

```
./restart.sh --project NAME --bootstrap-password PASS --postgres-password PASS --secret-key KEY [--beta|--prod|--dev]
```

Run `./restart.sh --help` for full options.

### stop.sh

```
./stop.sh --project NAME [--beta|--prod|--dev|--all]
```

Run `./stop.sh --help` for full options.

### setup-nginx.sh

```bash
sudo ./setup-nginx.sh --domain <domain> --port <port> [--force]

Examples:
  sudo ./setup-nginx.sh --domain member.example.com --port 8001
  sudo ./setup-nginx.sh --domain api.example.com --port 8000
```

### setup-security.sh

```bash
sudo ./setup-security.sh --domain <domain> [--domain <domain> ...]

Example:
  sudo ./setup-security.sh --domain api.example.com --domain member.example.com
```

Applies security to all specified domains:
- UFW firewall (ports 22, 80, 443 only)
- Nginx rate limiting
- Fail2ban for brute force protection

## Container Names

Containers are named based on project and environment:

| Environment | Containers |
|-------------|------------|
| beta | `<project>-beta-server`, `<project>-beta-postgres` |
| prod | `<project>-prod-server`, `<project>-prod-postgres` |
| dev | `<project>-dev-server`, `<project>-dev-postgres` |

```bash
# View running containers (replace myproduct with your project name)
docker ps | grep myproduct-

# View logs
docker logs myproduct-beta-server
docker logs myproduct-prod-server
```

## CORS Configuration

CORS origins are configured via `--allowed-websites`:

| Environment | CORS Origins |
|-------------|--------------|
| beta | `https://<site>` (from `--allowed-websites`) |
| prod | `https://<site1>,https://<site2>,...` (from `--allowed-websites s1,s2`) |
| dev | `*` (all origins, no `--allowed-websites` needed) |

## Running Both Environments

You can run beta and production simultaneously:

```bash
# Deploy both
./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password betapass123 --postgres-password dbpass123 \
  --allowed-websites beta.example.com

./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password prodpass123 --postgres-password dbpass123 \
  --allowed-websites www.example.com,example.com --prod

# Setup nginx for both
sudo ./setup-nginx.sh --domain member.example.com --port 8001
sudo ./setup-nginx.sh --domain api.example.com --port 8000

# Setup security (covers both)
sudo ./setup-security.sh --domain api.example.com --domain member.example.com
```

## Updating the Server

### Update Beta (safe for testing)

```bash
./stop.sh --project myproduct
./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password betapass --postgres-password dbpass \
  --allowed-websites beta.example.com
```

### Update Production (careful!)

```bash
./stop.sh --project myproduct --prod
./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password prodpass --postgres-password dbpass \
  --allowed-websites www.example.com,example.com --prod
```

## Credentials

The deploy script outputs credentials at the end. Save them securely:
- **Bootstrap password** - For the admin user (can be changed on each run)
- **Postgres password** - Database password (fixed once created)
- **Secret key** - JWT signing key (auto-generated if not provided)

**Important:** When using `restart.sh`, provide the same postgres password and secret key.

## Troubleshooting

### Container not starting
```bash
docker logs myproduct-beta-server
docker logs myproduct-prod-server
```

### Check environment variables
```bash
docker exec myproduct-beta-server env | grep -E "CORS|ENVIRONMENT|PROJECT"
```

### Database connection issues
```bash
docker exec -it myproduct-beta-postgres psql -U myproduct -d myproduct
```

### Check nginx status
```bash
sudo systemctl status nginx
sudo nginx -t
sudo tail -f /var/log/nginx/error.log
```

### Renew SSL certificate
```bash
sudo certbot renew --dry-run  # Test
sudo certbot renew            # Actually renew
```

## Security

### Firewall (UFW)
Only these ports are open:
- **22** - SSH
- **80** - HTTP (redirects to HTTPS)
- **443** - HTTPS

Database port is NOT exposed - only accessible within Docker network.

### Rate Limiting
Nginx rate limits protect against abuse:
- **Auth endpoints** (`/v1/auth/`): 5 req/s
- **API endpoints** (`/api/`): 10 req/s
- **General**: 20 req/s

### Fail2ban
Automatically bans IPs that:
- Exceed rate limits (1 hour ban)
- Generate too many 4xx errors (24 hour ban)
- Fail authentication repeatedly (1 hour ban)

```bash
# Check banned IPs
sudo fail2ban-client status nginx-limit-req

# Unban an IP
sudo fail2ban-client unban <IP>
```

### Direct IP Access
Direct access via server IP is blocked. Only requests via the domain name are accepted.
