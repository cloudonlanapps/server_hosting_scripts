# Club Server Docker Deployment

Deploy the Club Server using Docker with nginx reverse proxy and HTTPS. Supports multiple environments (beta, production, development) on the same server.

## Architecture

```
                      ┌─────────────────────────────────────┐
                      │           Same Linux VPS            │
                      │                                     │
beta.domain.com ──────┼──► Nginx ──► :8001 ──► club-beta   │
                      │                                     │
www.domain.com  ──────┼──► Nginx ──► :8000 ──► club-prod   │
domain.com      ──────┤                                     │
                      └─────────────────────────────────────┘
```

## Environments

| Environment | API Domain | Frontend | Port | Data Directory | Git Branch | Default |
|-------------|------------|----------|------|----------------|------------|---------|
| **beta** | `member.<domain>` | `beta.<domain>` | 8001 | `/var/lib/club-server-beta` | `main` | ✓ (safe) |
| **prod** | `api.<domain>` | `www.<domain>` | 8000 | `/var/lib/club-server` | `release` | |
| **dev** | `localhost` | `localhost:*` | 8000 | `./data` | `main` | |

**Safety:** Scripts default to beta to prevent accidental production updates.

## Quick Start

### macOS Development

```bash
cd server_docker_from_git
chmod +x *.sh

# Deploy in development mode (default: beta, but --dev uses ./data and allows all CORS)
./deploy.sh --bootstrap-password mybootstrappass --postgres-password mydbpass --dev

# Server accessible at http://localhost:8000
curl http://localhost:8000/health
```

### Linux Server - Beta Environment

```bash
# Deploy beta (default - SAFE)
./deploy.sh --bootstrap-password mybootstrappass --postgres-password mydbpass --allowed-websites beta.example.com

# Setup nginx for beta
sudo ./setup-nginx.sh --domain member.example.com --port 8001

# Verify
curl https://member.example.com/health
```

### Linux Server - Production Environment

```bash
# Deploy production (explicit flag required)
./deploy.sh --bootstrap-password mybootstrappass --postgres-password mydbpass --allowed-websites www.example.com,example.com --prod

# Setup nginx for production
sudo ./setup-nginx.sh --domain api.example.com --port 8000

# Setup security (applies to both environments)
sudo ./setup-security.sh --domain api.example.com --domain member.example.com

# Verify
curl https://api.example.com/health
```

## Command Reference

### deploy.sh

```
./deploy.sh --bootstrap-password PASS --postgres-password PASS [options]
```

Run `./deploy.sh --help` for full options.

### restart.sh

Reads non-secret config (port, data-dir, allowed-websites) from `.deploy.env` saved by `deploy.sh`.

```
./restart.sh --bootstrap-password PASS --postgres-password PASS --secret-key KEY --beta|--prod|--dev
```

Run `./restart.sh --help` for full options.

### stop.sh

```bash
./stop.sh [options]

Options:
  --prod              Stop production containers
  --dev               Stop development containers
  --all               Stop all environments (beta, prod, dev)
  (default)           Stop beta containers
```

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

Containers are named based on environment:

| Environment | Containers |
|-------------|------------|
| beta | `club-beta-server`, `club-beta-postgres` |
| prod | `club-prod-server`, `club-prod-postgres` |
| dev | `club-dev-server`, `club-dev-postgres` |

```bash
# View running containers
docker ps | grep club-

# View logs for beta
docker logs club-beta-server

# View logs for production
docker logs club-prod-server
```

## CORS Configuration

CORS origins are configured via environment variable `CORS_ALLOWED_ORIGINS`:

| Environment | CORS Origins |
|-------------|--------------|
| beta | `https://<site>` (from `--allowed-websites`) |
| prod | `https://<site1>,https://<site2>,...` (from `--allowed-websites s1,s2`) |
| dev | `*` (all origins, no `--allowed-websites` needed) |

To verify CORS settings:
```bash
docker exec club-beta-server env | grep CORS
docker exec club-prod-server env | grep CORS
```

## Running Both Environments

You can run beta and production simultaneously:

```bash
# Deploy beta (default)
./deploy.sh --bootstrap-password betapass123 --postgres-password dbpass123 --allowed-websites beta.example.com

# Deploy production
./deploy.sh --bootstrap-password prodpass123 --postgres-password dbpass123 --allowed-websites www.example.com,example.com --prod

# Verify both running
docker ps | grep club-
# Should show 4 containers:
# club-beta-server, club-beta-postgres
# club-prod-server, club-prod-postgres

# Setup nginx for both
sudo ./setup-nginx.sh --domain member.example.com --port 8001
sudo ./setup-nginx.sh --domain api.example.com --port 8000

# Setup security (covers both)
sudo ./setup-security.sh --domain api.example.com --domain member.example.com
```

## Updating the Server

### Update Beta (safe for testing)

```bash
./stop.sh                              # Stops beta only
./deploy.sh --bootstrap-password betapass --postgres-password dbpass --allowed-websites beta.example.com
```

### Update Production (careful!)

```bash
./stop.sh --prod                              # Stops prod only
./deploy.sh --bootstrap-password prodpass --postgres-password dbpass --allowed-websites www.example.com,example.com --prod
```

## Credentials

The deploy script outputs credentials at the end. Save them securely:
- **Bootstrap password** - For the "sudo" admin user
- **Postgres password** - Database password
- **Secret key** - JWT signing key (auto-generated if not provided)

**Important:** When using `restart.sh`, you must provide the same secret key used during initial deployment.

## Troubleshooting

### Container not starting
```bash
docker logs club-beta-server
docker logs club-prod-server
```

### Check environment variables
```bash
docker exec club-beta-server env | grep -E "CORS|ENVIRONMENT"
```

### Database connection issues
```bash
docker exec -it club-beta-postgres psql -U myclub -d myclub
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
