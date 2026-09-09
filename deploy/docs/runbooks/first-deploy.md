# Runbook: standing up a core banking environment from nothing

The order below is not interchangeable. Each step assumes the one before it.

## What you need before starting

| Thing | Where it comes from |
|---|---|
| A droplet, 4 vCPU and 8 GB, on a private network with Main-Server | DigitalOcean, created by hand or with `doctl` |
| The age private key for this environment | `~/.config/age/malipopay-cbs-<env>.key`, generated 2026-09-10 |
| DNS records for the API host and the console host | Cloudflare |
| The addresses allowed to reach the system | Main-Server's private IP, plus named operator addresses |
| Docker Hub credentials, if CI is to build the image | The same account `malipopay-social` publishes under |

Do not skip the private network. Fineract accepts HTTP basic authentication by default, so
an instance reachable from the public internet is a core banking system exposed to password
guessing.

## 1. The host

```bash
ssh root@<droplet>
git clone https://github.com/Malipopay/malipopay-fineract.git /opt/malipopay-cbs/src
cd /opt/malipopay-cbs/src && git checkout malipopay
cp -r deploy /opt/malipopay-cbs/deploy
sudo /opt/malipopay-cbs/deploy/scripts/host-bootstrap.sh uat
```

It installs Docker, SOPS, the deploy user and the state directories, and closes the
firewall. It prints five things it deliberately does not do. Read them.

## 2. The keys

The age private key is carried by a person, once, and never by a pipeline.

```bash
# from your own machine, not from a shared terminal
scp ~/.config/age/malipopay-cbs-uat.key cbsdeploy@<droplet>:/etc/malipopay-cbs/age/uat.key
ssh cbsdeploy@<droplet> 'chmod 600 /etc/malipopay-cbs/age/uat.key'

# the public half, so backup.sh can encrypt without holding the private key
age-keygen -y ~/.config/age/malipopay-cbs-uat.key | \
  ssh cbsdeploy@<droplet> 'cat > /etc/malipopay-cbs/age/uat.pub'
```

Check it decrypts before going further. If this fails, everything after it fails in a way
that looks like something else:

```bash
ssh cbsdeploy@<droplet> \
  'SOPS_AGE_KEY_FILE=/etc/malipopay-cbs/age/uat.key sops --decrypt --input-type dotenv \
   --output-type dotenv /opt/malipopay-cbs/deploy/env/.env.uat.enc | grep -c "="'
# expect 43
```

## 3. TLS and the allow list

```bash
sudo CBS_HOST=fineract-uat.malipopay.co.tz \
     CONSOLE_HOST=cbs-console-uat.malipopay.co.tz \
     CBS_ALLOW="<Main-Server private IP>/32 <office CIDR>" \
     /opt/malipopay-cbs/deploy/nginx/render.sh

sudo certbot certonly --nginx -d fineract-uat.malipopay.co.tz -d cbs-console-uat.malipopay.co.tz
sudo systemctl reload nginx
```

Then prove the allow list from an address that is not on it. Expect 403, not a login
prompt. A rule nobody has tried from the wrong side is not a rule.

## 4. The image

Either build it in CI, by tagging the fork:

```bash
git tag mp/1.15.0-mp.1 && git push origin mp/1.15.0-mp.1
```

which needs `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` on the repository. Or build it on a
machine with a JDK 21 and push it by hand. Either way the tag must match
`deploy/UPSTREAM_VERSION`, and the build workflow refuses if it does not.

## 5. The first release

```bash
/opt/malipopay-cbs/deploy/scripts/release.sh uat lockwoodtech/malipopay-fineract:1.15.0-mp.1
```

First boot is the slow one: Liquibase creates and migrates both databases. The health gate
allows seven minutes and prints the container log if it runs out.

## 6. The tenant and the accounts

Business dates drive close of business, so turn them on and check the date is today in
Dar es Salaam:

```bash
curl -s -X PUT -u mifos:<seeded password> \
  -H "Fineract-Platform-TenantId: uat" -H "Content-Type: application/json" \
  -d '{"enabled":true}' \
  https://fineract-uat.malipopay.co.tz/fineract-provider/api/v1/configurations/name/enable-business-date
```

Then create the service account and the console users from
`service-account.md`, using the password already generated in the environment file, and
change the seeded `mifos` password. Until `CBS_SERVICE_USERNAME` and `CBS_SERVICE_PASSWORD`
resolve, `release.sh` can only prove the port answers.

## 7. Prove it, and read the output

```bash
CBS_BASE=https://fineract-uat.malipopay.co.tz \
CBS_USER=malipopay_svc CBS_PASS=<from the env file> \
  /opt/malipopay-cbs/deploy/scripts/proof.sh uat
```

Twenty one checks. The one that matters is the replayed deposit: the same idempotency key
must return the original transaction with `x-served-from-cache: true` and leave the balance
where it was. Save the output next to `proof-2026-09-09.md`.

## 8. The things that are only done once and are always forgotten

- The nightly backup cron for the deploy user.
- `rclone` configured at `/etc/malipopay-cbs/rclone.conf` for the backup bucket.
- A restore drill into a scratch database, and the date of it written down.
- The Fineract users added to the leavers checklist. It is a separate user store from
  Malipopay's, which is why it is the one people forget.
