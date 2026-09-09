#!/usr/bin/env bash
# Prepare a fresh Ubuntu droplet to host the core banking stack. Run once, as root.
#
#   sudo ./host-bootstrap.sh uat
#
# It installs Docker, creates the deploy user and the state directories, and closes the
# firewall. It deliberately does NOT install the age keys, the environment ciphertext or the
# TLS certificates: those are carried by a person, once, and the script says so at the end.
set -euo pipefail

ENV_NAME="${1:?usage: host-bootstrap.sh <uat|production>}"
DEPLOY_USER="${DEPLOY_USER:-cbsdeploy}"
[[ "$(id -u)" -eq 0 ]] || { echo "run as root" >&2; exit 1; }

echo "==> packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg ufw unattended-upgrades \
  nginx age rclone jq

echo "==> docker engine"
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

echo "==> sops"
if ! command -v sops >/dev/null; then
  SOPS_VER=3.9.0
  curl -fsSL -o /usr/local/bin/sops \
    "https://github.com/getsops/sops/releases/download/v${SOPS_VER}/sops-v${SOPS_VER}.linux.$(dpkg --print-architecture)"
  chmod 0755 /usr/local/bin/sops
fi

echo "==> deploy user and directories"
id -u "$DEPLOY_USER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$DEPLOY_USER"
usermod -aG docker "$DEPLOY_USER"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /var/lib/malipopay-cbs
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /var/backups/malipopay-cbs
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /etc/malipopay-cbs/age
install -d -m 750 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/malipopay-cbs

echo "==> firewall"
# Default deny inbound. SSH from anywhere is deliberate only if there is no bastion; narrow
# it to the office range as soon as one exists.
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'ssh'
# 443 is NOT opened to the world here. The NGINX vhost carries its own allow list, and the
# allowed source addresses are supplied at render time, never committed to this repository.
ufw allow 443/tcp comment 'https, further restricted by the nginx allow list'
ufw --force enable

echo "==> unattended security updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF

echo "==> docker daemon log limits"
cat > /etc/docker/daemon.json <<'CONF'
{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "5" } }
CONF
systemctl restart docker

echo
echo "Host prepared for ${ENV_NAME}. Five things are still owed, and each needs a person:"
echo "  1. Install the age private key at /etc/malipopay-cbs/age/${ENV_NAME}.key (mode 600,"
echo "     owned by ${DEPLOY_USER}) and the matching public key at ${ENV_NAME}.pub for backups."
echo "  2. Render and enable the NGINX vhost, filling in the allowed source addresses:"
echo "       deploy/nginx/render.sh, then certbot --nginx -d <host>"
echo "  3. Configure rclone at /etc/malipopay-cbs/rclone.conf for the backup bucket."
echo "  4. Add the nightly backup cron for ${DEPLOY_USER}:"
echo "       15 1 * * * /opt/malipopay-cbs/deploy/scripts/backup.sh ${ENV_NAME} nightly"
echo "  5. Create the Fineract service account and record it in the environment file"
echo "     (deploy/docs/runbooks/service-account.md). Until then release.sh can only prove"
echo "     that the port answers, not that the API works."
