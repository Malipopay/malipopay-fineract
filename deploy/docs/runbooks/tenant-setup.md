# Runbook: tenants and environments

## One tenant per environment, not per merchant

Fineract's multi-tenancy gives each tenant its own database. The tempting reading is one
tenant per merchant. That is wrong here, and the mistake is expensive to undo.

Merchants are a Malipopay concept: a merchant has an account with the bank, exactly as a
customer does. Fineract's tenant boundary is an institution boundary, and Malipopay is one
institution. Using it per merchant would give you hundreds of databases, hundreds of copies
of the chart of accounts, no cross-merchant reporting, and a close-of-business job that has
to run per merchant.

So: `uat`, `staging` and `prod` are the tenants, one per Malipopay environment, selected by
the `Fineract-Platform-TenantId` header the middleware sets on every call.

## Creating one

The first tenant is created at boot from `FINERACT_DEFAULT_TENANTDB_*`. Set the identifier
and database name in the environment file before the first start on an empty volume;
changing them afterwards does not rename anything.

Two values are worth pausing over.

**Timezone.** `FINERACT_TENANT_TIMEZONE=Africa/Dar_es_Salaam`, not upstream's sample
`Asia/Kolkata`. The tenant timezone decides business dates, so it decides which day a
transaction belongs to and when close of business draws its line. A wrong timezone puts
evening transactions on the wrong day, and every report built on that is wrong with it.

**Master password.** `FINERACT_TENANT_MASTER_PASSWORD` encrypts the per-tenant database
credentials held in the tenants registry. Rotating it after the first boot needs the stored
credentials re-encrypted; it is not a value to change casually.

## Adding a second tenant later

A second tenant on the same instance is added through the tenants registry, not through the
environment file. Plan it: it needs its own database, its own chart of accounts, its own
products and its own close-of-business schedule.

## Business dates

Several Fineract behaviours, close of business among them, depend on business dates being
switched on:

```bash
curl -s -X PUT -u <svc> -H "Fineract-Platform-TenantId: uat" \
  -H "Content-Type: application/json" -d '{"enabled":true}' \
  https://<host>/fineract-provider/api/v1/configurations/name/enable-business-date
```

Check the business date matches the real date in Dar es Salaam after enabling it, and again
after any restore: a restored database carries the business date it had when it was dumped.
