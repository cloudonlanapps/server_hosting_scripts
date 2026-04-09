# FastAPI Server Docker Deployment

Deploy any FastAPI server using Docker with nginx reverse proxy and HTTPS. Supports beta, production, and development environments on the same server.

Run `./deploy.sh --help` for the full naming convention and all options.

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

## Quick Start

### Development

```bash
chmod +x *.sh

./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password mybootstrappass --postgres-password mydbpass --dev

curl http://localhost:8000/health
```

### Linux Server

```bash
# Beta (default, safe)
./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password mybootstrappass --postgres-password mydbpass \
  --allowed-websites beta.example.com

# Production
./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password mybootstrappass --postgres-password mydbpass \
  --allowed-websites www.example.com,example.com --prod

# Nginx & security (one-time)
sudo ./setup-nginx.sh --domain member.example.com --port 8001
sudo ./setup-nginx.sh --domain api.example.com --port 8000
sudo ./setup-security.sh --domain api.example.com --domain member.example.com
```

## Scripts

| Script | Purpose | Help |
|--------|---------|------|
| `deploy.sh` | Build and deploy | `./deploy.sh --help` |
| `restart.sh` | Restart existing deployment | `./restart.sh --help` |
| `stop.sh` | Stop containers | `./stop.sh --help` |
| `setup-nginx.sh` | Configure nginx reverse proxy | `sudo ./setup-nginx.sh --help` |
| `setup-security.sh` | Configure firewall, rate limiting, fail2ban | `sudo ./setup-security.sh --help` |
| `audit-security.sh` | Audit security configuration | `sudo ./audit-security.sh --help` |

## Troubleshooting

```bash
# Container logs
docker logs <project>-<env>-server      # e.g., myproduct-beta-server

# Environment variables
docker exec <project>-<env>-server env | grep -E "CORS|ENVIRONMENT|PROJECT"

# Database
docker exec -it <project>-<env>-postgres psql -U <project> -d <project>

# Nginx
sudo nginx -t
sudo tail -f /var/log/nginx/error.log

# SSL
sudo certbot renew --dry-run
```
