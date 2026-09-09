# Environment files

| File | Purpose | Committed |
|---|---|---|
| `fineract.env.example` | Template with every variable and why it is set that way | yes |
| `.sops.yaml` | Age recipients, one per environment | yes |
| `.env.uat` / `.env.production` / `.env.local` | Filled plaintext | never |
| `.env.uat.enc` / `.env.production.enc` | SOPS ciphertext, what the deploy reads | yes |

## Rules

1. Plaintext env files are gitignored. Check with `git check-ignore -v deploy/env/.env.uat`
   before writing one.
2. Re-encrypt from the decrypted ciphertext, never from a local plaintext file that may
   have drifted. Encrypting from a stale copy silently ships whatever it is missing, and
   the git diff cannot catch it because SOPS rekeys the whole file on every write.

   ```bash
   sops --decrypt --input-type dotenv --output-type dotenv .env.uat.enc > /tmp/cur.env
   # edit /tmp/cur.env
   diff <(sort /tmp/cur.env) <(sort /tmp/new.env)   # read this diff, value by value
   sops --encrypt --input-type dotenv --output-type dotenv /tmp/new.env > .env.uat.enc
   ```
3. Every secret is generated, not chosen: `openssl rand -base64 32`.
4. Rotating `FINERACT_TENANT_MASTER_PASSWORD` after the first boot re-encrypts stored tenant
   credentials. Read `docs/malipopay/runbooks/tenant-setup.md` first.
