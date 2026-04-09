# Quick Setup Guide

## Understanding Environments

`--dev`, `--beta`, `--prod` are **mutually exclusive** - use only ONE:

| Flag | Environment | Port | Data Directory | CORS | Use Case |
|------|-------------|------|----------------|------|----------|
| `--dev` | Development | 8000 | `./data-<project>` | `*` (all) | macOS local dev |
| (none) | Beta | 8001 | `/var/lib/<project>-server-beta` | from `--allowed-websites` | Linux testing |
| `--prod` | Production | 8000 | `/var/lib/<project>-server` | from `--allowed-websites` | Linux production |

**Default is BETA** - safe, won't touch production.

---

## Understanding Domains

All domain names are passed explicitly via `--domain` — nothing is hardcoded.

```
Example setup:

Nginx reverse proxy (created by setup-nginx.sh):
├── member.example.com  → port 8001 (beta API)
└── api.example.com     → port 8000 (prod API)

CORS origins (passed to deploy.sh via --allowed-websites):
├── beta.example.com    → beta frontend
├── www.example.com     → prod frontend
└── example.com         → prod frontend
```

**CORS allows requests FROM frontend TO API** - the scripts only set up API reverse proxies.

---

## 1. Production

**Setup nginx (one-time):**
```bash
sudo ./setup-nginx.sh --domain api.example.com --port 8000
```

**Deploy:**
```bash
./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password <pw> --postgres-password <pw> \
  --allowed-websites www.example.com,example.com --prod
```

**Restart (preserves data):**
```bash
./restart.sh --project myproduct --bootstrap-password <pw> --postgres-password <pw> --secret-key <key> --prod
```

**Stop:**
```bash
./stop.sh --project myproduct --prod
```

**Verify:**
```bash
curl http://localhost:8000/health              # Direct
curl https://api.example.com/health            # Via nginx
```

---

## 2. Beta

**Setup nginx (one-time):**
```bash
sudo ./setup-nginx.sh --domain member.example.com --port 8001
```

**Deploy:**
```bash
./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password <pw> --postgres-password <pw> \
  --allowed-websites beta.example.com
```

**Restart (preserves data):**
```bash
./restart.sh --project myproduct --bootstrap-password <pw> --postgres-password <pw> --secret-key <key> --beta
```

**Stop:**
```bash
./stop.sh --project myproduct
```

**Verify:**
```bash
curl http://localhost:8001/health                   # Direct
curl https://member.example.com/health              # Via nginx
```

---

## 3. Development (macOS)

**No nginx needed** - direct access to port 8000.

**Deploy:**
```bash
./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password <pw> --postgres-password <pw> --dev
```

**Restart (preserves data):**
```bash
./restart.sh --project myproduct --bootstrap-password <pw> --postgres-password <pw> --secret-key <key> --dev
```

**Stop:**
```bash
./stop.sh --project myproduct --dev
```

**Verify:**
```bash
curl http://localhost:8000/health
```

**Flutter connection:** Your Flutter app connects to `http://localhost:8000/v1`

---

## Running Both Beta and Production (Linux)

You can run both simultaneously on the same server:

```bash
# Deploy both
./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password betapass --postgres-password dbpass --allowed-websites beta.example.com

./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password prodpass --postgres-password dbpass \
  --allowed-websites www.example.com,example.com --prod

# Setup nginx for both
sudo ./setup-nginx.sh --domain member.example.com --port 8001
sudo ./setup-nginx.sh --domain api.example.com --port 8000

# Setup security (covers both)
sudo ./setup-security.sh --domain api.example.com --domain member.example.com

# Verify both running
docker ps | grep myproduct-
# myproduct-beta-server, myproduct-beta-postgres (port 8001)
# myproduct-prod-server, myproduct-prod-postgres (port 8000)
```

---

## Precautions

1. **Scripts default to BETA** - Running without `--prod` is safe
2. **Save your credentials** - The secret key is needed for restarts
3. **Never share credentials** - Keep bootstrap_pw, postgres_pw, and secret_key private
4. **Test in beta first** - Always deploy to beta before production
5. **Don't combine flags** - `--dev --prod` is WRONG, use only ONE
6. **Check container status** after deployment:
   ```bash
   docker ps | grep myproduct-
   ```

---

## Danger Zone

### Reset Database (DELETES ALL DATA)
```bash
# Beta - fresh database
./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password <pw> --postgres-password <pw> --allowed-websites beta.example.com --reset

# Production - fresh database (CAREFUL!)
./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \
  --bootstrap-password <pw> --postgres-password <pw> \
  --allowed-websites www.example.com,example.com --prod --reset
```

### Stop All Environments
```bash
./stop.sh --project myproduct --all
```

### Recreate nginx config (if SSL exists)
```bash
# Creates backup, then overwrites
sudo ./setup-nginx.sh --domain member.example.com --port 8001 --force
sudo ./setup-nginx.sh --domain api.example.com --port 8000 --force
```

### View Logs When Things Go Wrong
```bash
# Beta logs
docker logs myproduct-beta-server
docker logs myproduct-beta-postgres

# Production logs
docker logs myproduct-prod-server
docker logs myproduct-prod-postgres

# Nginx logs
sudo tail -f /var/log/nginx/error.log
```

---

## Quick Reference Table

| Action | Beta (default) | Production | Dev (macOS) |
|--------|----------------|------------|-------------|
| Deploy | `./deploy.sh --project P --git-url U ... --allowed-websites S` | `... --prod` | `... --dev` |
| Stop | `./stop.sh --project P` | `... --prod` | `... --dev` |
| Port | 8001 | 8000 | 8000 |
| Data Dir | `/var/lib/<project>-server-beta` | `/var/lib/<project>-server` | `./data-<project>` |
| Containers | `<project>-beta-*` | `<project>-prod-*` | `<project>-dev-*` |
