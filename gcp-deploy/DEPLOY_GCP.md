# Deploy FreeLLMAPI to Google Cloud (Always Free, $0/month)

Self-host [FreeLLMAPI](https://github.com/tashfeenahmed/freellmapi) on a GCP
**e2-micro** (Always Free tier) behind a **Caddy** reverse proxy with a free
**DuckDNS** domain and automatic Let's Encrypt HTTPS.

**Total cost: $0/month** (within GCP Always Free allowances). Guardrails
(budget alert + quota caps) make it impossible to exceed the free tier.

> Last verified against: GCP billing account with free-trial credit,
> `gcloud` CLI, Ubuntu 24.04 LTS, Docker 29.x. August 2026.

---

## Architecture

```
Internet
   │  https://<your>.duckdns.org
   ▼
Caddy (ports 80/443, auto Let's Encrypt)
   │  reverse_proxy localhost:3001
   ▼
FreeLLMAPI container (127.0.0.1:3001 only — never exposed directly)
   │
   ▼
SQLite (encrypted keys) in `freellmapi-data` volume
```

- The app container binds to **localhost only**; Caddy is the only public
  entry point. This keeps the single-user proxy off the open internet.
- Static IP + DuckDNS cron updater keep the domain stable across reboots.

---

## Prerequisites

1. A Google account with billing enabled (any credit card; you won't be charged).
2. `gcloud` CLI installed and authenticated:
   ```bash
   gcloud auth login
   gcloud auth application-default login   # optional, for API calls
   ```
3. Docker + Docker Compose on your local machine (to generate keys, optional).

---

## Phase 1 — Project & billing

```bash
# Use a project ID that's globally unique
gcloud projects create freellmapi-live --name="FreeLLMAPI"

# Link billing (replace ACCOUNT_ID with your billing account id)
gcloud beta billing projects link freellmapi-live \
  --billing-account=XXXXXX-XXXXXX-XXXXXX

gcloud config set project freellmapi-live
```

### Budget guardrail ($0.01 — GCP minimum; alerts before any spend)

```bash
gcloud services enable billingbudgets.googleapis.com

gcloud billing budgets create \
  --billing-account=XXXXXX-XXXXXX-XXXXXX \
  --display-name="FreeLLMAPI $0 guardrail" \
  --budget-amount=0.01 \
  --threshold-rule=percent=1.0
```

An email fires at $0.01 spend — long before anything meaningful accrues.

---

## Phase 2 — SSH key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/freellmapi_gcp -C freellmapi-deploy -N ""
```

---

## Phase 3 — VM (e2-micro, Always Free)

```bash
gcloud compute instances create freellmapi-vm \
  --zone=us-west1-b \
  --machine-type=e2-micro \
  --image-family=ubuntu-2404-lts --image-project=ubuntu-os-cloud \
  --boot-disk-size=30GB --boot-disk-type=pd-standard \
  --tags=freellmapi-app \
  --metadata=ssh-keys="ubuntu:$(cat ~/.ssh/freellmapi_gcp.pub)"

# Static IP (keeps DuckDNS stable; release it if you ever delete the VM)
gcloud compute addresses create freellmapi-ip --region=us-west1
gcloud compute instances delete-access-config freellmapi-vm \
  --access-config-name="external-nat" --zone=us-west1-b
gcloud compute instances add-access-config freellmapi-vm \
  --access-config-name="external-nat" --address=YOUR_STATIC_IP \
  --zone=us-west1-b

# SSH in
ssh -i ~/.ssh/freellmapi_gcp ubuntu@YOUR_STATIC_IP
```

> e2-micro = 2 vCPU-share / 1GB RAM, included in Always Free.
> 30GB pd-standard is also within the free 200GB disk allowance.

---

## Phase 4 — Firewall (lock it down)

```bash
# SSH only from YOUR IP (replace with your public IP from api.ipify.org)
gcloud compute firewall-rules update default-allow-ssh \
  --source-ranges=YOUR_PUBLIC_IP/32

# Web traffic only to the VM carrying the freellmapi-app tag
gcloud compute firewall-rules create allow-web \
  --allow=tcp:80,tcp:443 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=freellmapi-app \
  --priority=1000

# Remove anything you don't need
gcloud compute firewall-rules delete default-allow-rdp -q
```

### Quota caps (hard ceiling = free tier, cannot accidentally scale up)

```bash
for q in CPUS-ALL-REGIONS CPUS-per-project-region \
         STATIC-ADDRESSES-per-project-region IN-USE-ADDRESSES-per-project-region \
         INSTANCES-per-project-region; do
  gcloud quotas preferences update $q \
    --preferred-value=2 \
    --allow-high-percentage-quota-decrease --allow-missing \
    --project=freellmapi-live
done

gcloud quotas preferences update DISKS-TOTAL-GB-per-project-region \
  --preferred-value=60 \
  --allow-high-percentage-quota-decrease --allow-missing \
  --project=freellmapi-live
```

---

## Phase 5 — Domain (DuckDNS, free)

1. Sign in at **https://duckdns.org** (Google/GitHub OAuth).
2. **Add Domain** → pick a subdomain, e.g. `myproxy`.
3. Copy the **token** shown.
4. Point it at your static IP:
   ```bash
   curl -k "https://www.duckdns.org/update?domains=myproxy&token=YOUR_TOKEN&ip=YOUR_STATIC_IP"
   # expect: OK
   ```

### Auto-update cron (runs every 5 min, free)

Copy `duckdns-updater.sh` to the VM as `/opt/duckdns/duck.sh` (fill in your
token), then:

```bash
sudo chmod 700 /opt/duckdns/duck.sh
( sudo crontab -l 2>/dev/null | grep -v duckdns; \
  echo "*/5 * * * * /opt/duckdns/duck.sh >/dev/null 2>&1" ) | sudo crontab -
```

---

## Phase 6 — OS + Docker on the VM

```bash
sudo apt update && sudo apt upgrade -y && sudo reboot
# wait ~1 min, reconnect

sudo apt install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker ubuntu   # re-login after this
```

---

## Phase 7 — Deploy the app (prebuilt image, no build)

> **Use the published image — do NOT `docker compose up --build` on an
> e2-micro.** Compiling the multi-stage Node image on 1GB RAM thrashes the
> box into unreachability (SSH hangs, systemd flushes caches). The GHCR
> image pulls in seconds.

```bash
sudo git clone https://github.com/tashfeenahmed/freellmapi.git /opt/freellmapi
sudo chown -R ubuntu:ubuntu /opt/freellmapi
cd /opt/freellmapi

# One-time encryption key (keep it! it encrypts your provider keys at rest)
ENCRYPTION_KEY="$(openssl rand -hex 32)"
cat > .env <<EOF
PORT=3001
ENCRYPTION_KEY=$ENCRYPTION_KEY
EOF

docker compose up -d --no-build
docker compose ps          # expect: Up (healthy)
curl -s localhost:3001/api/ping   # expect: {"status":"ok",...}
```

First-run setup code + unified API key appear in the logs:

```bash
docker compose logs | grep -E 'setup code|unified API key'
```

### Encrypted backups (free, protects against DB corruption)

```bash
cat >> .env <<EOF
FREEAPI_DB_BACKUP_PATH=/app/server/data/freellmapi.db.backup
FREEAPI_DB_BACKUP_INTERVAL_MS=3600000
EOF
docker compose up -d
```

---

## Phase 8 — Caddy (HTTPS, auto certs)

Copy `Caddyfile` (adjust domain) to the VM as `/opt/caddy/Caddyfile`, then:

```bash
sudo docker run -d --name caddy --restart unless-stopped \
  --network host \
  -v /opt/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v caddy_data:/data -v caddy_config:/config \
  caddy:2

sudo docker logs caddy   # watch for "certificate obtained successfully"
```

Verify from anywhere:

```bash
curl -s https://myproxy.duckdns.org/api/ping
# expect: {"status":"ok",...}   (HTTP 200, valid cert)
```

Caddy renews certs automatically. No cron needed.

---

## Smoke test suite

| Test | Command | Expect |
|------|---------|--------|
| T1 dashboard | `curl -s https://<domain>/ -o /dev/null -w "%{http_code}"` | 200 |
| T2 ping | `curl -s https://<domain>/api/ping` | `{"status":"ok"}` |
| T3 models (valid key) | `curl -s -H "Authorization: Bearer <key>" https://<domain>/v1/models -o /dev/null -w "%{http_code}"` | 200 |
| T4 models (bad key) | same with `Bearer wrong` | 401 |
| T5 chat (no key) | `curl -s -X POST -H "Content-Type: application/json" -d '{"model":"auto","messages":[{"role":"user","content":"hi"}]}' https://<domain>/v1/chat/completions -o /dev/null -w "%{http_code}"` | 401 |
| T6 chat (valid key) | same with auth header | 503 until provider keys added (router correctly refuses with no providers) |

---

## Dashboard setup (first run)

1. Open `https://<domain>/` and enter the **setup code** from the logs.
2. Choose an admin email + password (dashboard login).
3. Add your provider keys on the **Keys** page (each provider's own free tier:
   Google, Groq, Cerebras, Mistral, OpenRouter, etc.).
4. Point clients at `https://<domain>/v1` with the unified key
   (`freellmapi-…` shown on the Keys page header).

---

## Cost guardrails recap

| Guardrail | What it does |
|---|---|
| Budget alert @ $0.01 | Email the instant any spend registers |
| Quota caps (2 CPU / 2 inst / 2 IPs / 60GB) | Hard ceiling = free tier; blocks accidental scale-up |
| SSH locked to your IP | No brute-force surface |
| App on localhost only | Caddy is the sole public entry point |
| Static IP | Stable domain; **release it if you delete the VM** (`gcloud compute addresses delete freellmapi-ip --region=us-west1`) — an unattached static IP bills ~$3.5/mo |

Always Free allowances relevant here (us-west1): e2-micro VM, 30GB of
standard disk, ~200GB/mo egress to NA — all covered by this setup.

---

## Updating the app

```bash
cd /opt/freellmapi
docker compose pull
docker compose up -d
```

Your `.env` (encryption key) and the `freellmapi-data` volume persist across
updates.
