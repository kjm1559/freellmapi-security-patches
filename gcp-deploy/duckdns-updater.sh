#!/bin/bash
# DuckDNS auto-updater — keeps your DuckDNS domain pointed at this VM.
# Place at /opt/duckdns/duck.sh on the VM, chmod 700, then add cron:
#   */5 * * * * /opt/duckdns/duck.sh >/dev/null 2>&1
#
# Get your token at https://duckdns.org after registering a domain.
# The DuckDNS update API is free and idempotent; it returns OK/KO.

TOKEN="REPLACE_WITH_DUCK_TOKEN"          # from your DuckDNS account
DOMAIN="YOUR-SUBDOMAIN"                  # your DuckDNS subdomain (no .duckdns.org)
IP="YOUR_STATIC_IP"                      # your GCP static IP (or "auto" to send detected IP)

URL="https://www.duckdns.org/update?domains=${DOMAIN}&token=${TOKEN}&ip=${IP}"
echo "url=${URL}" | curl -k -o /opt/duckdns/duck.log -s -K -
