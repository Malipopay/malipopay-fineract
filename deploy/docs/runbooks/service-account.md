# Runbook: Fineract users, roles and the service account

## The idea

Customer identity never reaches Fineract. Customers authenticate to Malipopay, and the
banking middleware calls Fineract as one machine account per environment. Fineract's user
store therefore holds two kinds of user and no third: the service account, and named
operations staff who use the console.

## The default superuser is not the service account

A fresh Fineract seeds `mifos` with a well known password and the "Super user" role. It is
the bootstrap credential and nothing else.

1. Change its password immediately after the first boot.
2. Create the service account and the named staff accounts.
3. Keep `mifos` for break-glass only, with its password stored where break-glass credentials
   are stored, and expect to be asked when it is used.

## Creating the service account

The middleware needs exactly what it calls, and it never needs to administer Fineract. Build
a role from the permissions its adapter actually uses, add one, and no more, when the adapter
gains a call.

```bash
# 1. The role
curl -s -X POST -u mifos:<password> \
  -H "Fineract-Platform-TenantId: uat" -H "Content-Type: application/json" \
  -d '{"name":"MALIPOPAY_MIDDLEWARE","description":"Banking middleware service account"}' \
  https://<host>/fineract-provider/api/v1/roles

# 2. The permissions, one PUT carrying the map
#    Start from: READ_CLIENT, CREATE_CLIENT, READ_SAVINGSACCOUNT, CREATE_SAVINGSACCOUNT,
#    APPROVE_SAVINGSACCOUNT, ACTIVATE_SAVINGSACCOUNT, DEPOSIT_SAVINGSACCOUNT,
#    WITHDRAWAL_SAVINGSACCOUNT, READ_SAVINGSPRODUCT, READ_OFFICE, READ_PAYMENTTYPE.
curl -s -X PUT -u mifos:<password> \
  -H "Fineract-Platform-TenantId: uat" -H "Content-Type: application/json" \
  -d '{"permissions":{"READ_CLIENT":true,"CREATE_CLIENT":true,"READ_SAVINGSACCOUNT":true}}' \
  https://<host>/fineract-provider/api/v1/roles/<roleId>/permissions

# 3. The user
curl -s -X POST -u mifos:<password> \
  -H "Fineract-Platform-TenantId: uat" -H "Content-Type: application/json" \
  -d '{"username":"malipopay_svc","firstname":"Malipopay","lastname":"Middleware",
       "email":"engineering@lockwood.co.tz","officeId":1,"roles":[<roleId>],
       "sendPasswordToEmail":false,"password":"<generated>","repeatPassword":"<generated>"}' \
  https://<host>/fineract-provider/api/v1/users
```

Put the credential in `CBS_SERVICE_USERNAME` and `CBS_SERVICE_PASSWORD` in the environment
file, re-encrypt with SOPS, and redeploy. Until both are set, `release.sh` can only prove
that the port answers, not that the API works.

## Prove the role is actually limited

Creating a narrow role and never testing it is the common failure. Try something the role
must not be able to do, and expect a refusal:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -u malipopay_svc:<password> \
  -H "Fineract-Platform-TenantId: uat" \
  -X POST -H "Content-Type: application/json" -d '{"name":"nope"}' \
  https://<host>/fineract-provider/api/v1/roles
# expect 403. A 200 means the service account can administer the core banking system.
```

## Operations console users

The console signs in as a Fineract user, so read-only is a property of the role, never of
the UI. Build a console role from `READ_*` permissions plus the specific maker actions that
job needs, and never give a console user "Super user". Where an action needs two people,
turn on Fineract's maker-checker for that permission rather than trusting a process note.

## Leavers

Disable the Fineract user the same day. It is a separate user store from Malipopay's, which
means it is the one people forget. Put it on the offboarding checklist.
