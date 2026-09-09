# Banking middleware, phase 1 implementation plan

> **For Claude and for whoever picks this up:** phase 1 builds the skeleton, not the product.
> Its purpose is that one canonical request reaches Fineract through an adapter interface and
> comes back as a Malipopay object, with identity, idempotency and audit already in place.
> No customer-facing feature ships in this phase.

**Goal.** Stand up `malipopay-banking-service` behind the core gateway so that
`/api/v1/banking/products` answers with a Malipopay product catalogue resolved through a
provider adapter from a real Fineract instance.

**Architecture.** Node 20 and TypeScript, Express 5, Mongoose against MongoDB Atlas, three
layers as every other Malipopay service (`index.ts` routes, `api.ts` handlers,
`repository/` business logic, `controllers/` data access), plus an `adapters/` tree that no
other layer may bypass. BullMQ on Redis for jobs, following the SMS service rather than the
central API's RabbitMQ helper, which has neither reconnect nor connection reuse.

**Tech stack.** Express 5, Mongoose 9, ioredis, BullMQ, Yup, Winston, openapi-comment-parser,
Jest. Ports 8040 production, 8041 UAT, 8042 staging. API status codes 3500 to 3599, a range
nothing else uses.

---

## Task 1: repository skeleton

**Files:** create `malipopay-banking-service/` from the ussd service layout, which is the
newest and the strictest.

Copy the shape, not the content: `src/{config,constants,controllers,entities,interfaces,loaders,modules,services,utils,test}`, `tsconfig.json` with the path aliases,
`jest.config.js` with `testPathIgnorePatterns` covering `/\.wt-`, the three env files, and
`.sops.yaml`.

Use the ussd service's `required()` helper in `src/config/index.ts`, which throws on a
missing variable, rather than the central API's silent `as string` casts. This service moves
money; a missing signing key must stop the boot, not surface as a runtime null.

**Verify:** `npm run build` succeeds and `node dist/app.js` listens on 8042 and answers
`GET /health` with the standard envelope.

---

## Task 2: identity

**Files:** `src/loaders/middleware.ts`, `src/services/jwt.service.ts`.

Port `protect` from the central API with one correction: verify with `JWT_PUBLIC_KEY`. The
central API verifies with the private key, which works because Node derives the public key
from a private PEM, and which means every service is deployed holding the RSA private key.
This service holds only the public key.

The gateway does not validate tokens. Its own route test says every route forwards without
gateway-level auth, and it injects only `x-tracking-id`, `x-forwarded-by`, `apitoken` and
`project`. So this service verifies for itself and trusts no inbound identity header.

Port the live-status revocation check as well: Malipopay tokens carry no expiry, so
deactivating a user does not retract a token already issued.

**Verify:** a request with no token gets 403 with the platform's contract, one with a valid
token reaches the handler, and one whose user has been deactivated gets 401 within the cache
window. Each observed, not assumed.

---

## Task 3: the adapter interface

**Files:** `src/adapters/types.ts`, `src/adapters/registry.ts`, `src/adapters/fineract/`.

Define `CoreBankingAdapter` in terms of Malipopay's canonical model. No Fineract field name
appears outside `src/adapters/fineract/`. Start with the calls phase 1 needs:
`listProducts`, `getCustomer`, `createIndividualCustomer`, `openDepositAccount`,
`getAccountBalance`, `getAccountTransactions`.

Generate the client rather than hand-writing it:
`./gradlew :fineract-client:buildTypescriptFetchSdk` in the fork produces a typescript-fetch
client from the exact spec of the pinned commit. Vendor the output under
`src/adapters/fineract/client/`. There is no published npm SDK.

The registry resolves an adapter per request from the product mapping and the customer's
stored provider references, so a second provider is a new implementation and a mapping row,
not a change anywhere above.

**Verify:** a conformance test suite runs green against a mock, and green against the local
Fineract compose stack in the fork.

---

## Task 4: idempotency and the outbox

**Files:** `src/entities/{IdempotencyRecord,BankingTransaction,OutboxEvent}.entity.ts`,
`src/repositories/idempotency.ts`.

Copy the pattern that already works in the central API's journal entity: a unique partial
index scoped to the state that must be unique, rather than a sparse index, which treats an
explicit null as a value.

Mint one idempotency key per instruction. Never per attempt. Fineract caches the first
response whatever it was, failures included, and replays it. A retry that reuses a failed
key replays the failure forever.

Write the state change and the outbox row in one MongoDB transaction, so an event cannot be
lost between the database and the broker.

**Verify:** a test that fires the same instruction twice concurrently and asserts one
Fineract call, one transaction row and one outbox row.

---

## Task 5: the first endpoint

**Files:** `src/modules/products/{index,api,repository/index,interfaces/index}.ts`.

`GET /api/v1/banking/products` returns the Malipopay catalogue: `productCode`, name,
category, currency, rates, channels, limits, mapped to a provider product underneath and
never exposing the provider's own shape.

**Verify:** `curl` it through the gateway on UAT and read the body. A green test is not this
check.

---

## Task 6: the gateway route

**Files:** in `malipopay-core-service`: `src/config/index.ts`, `src/modules/banking/index.ts`,
`src/loaders/routes.ts`, `src/loaders/__tests__/routes.test.ts`.

Copy `src/modules/central/index.ts` verbatim, change the target and the error label, add
`banking` to the allowlist array, add the health fan-out entry, and add the route to the
proxy list in the route test.

Keep every service-to-service endpoint under `/api/v1/internal/banking/*`. The gateway must
not route it, and the existing guard test asserts exactly that for the other internal
surfaces. Add banking's paths to it.

**Verify:** `/api/v1/banking/products` answers through `core-uat`, and
`/api/v1/internal/banking/anything` answers 404 at the gateway while answering 403 directly
on the host. Both observed.

---

## Task 7: the records

Add the service to `malipopay-docs/scripts/fetch-spec.sh` REPO_MAP or the docs dispatch fails
with "Unknown service". Add the PM2 entry to `/home/malipo_admin/ecosystem.config.js` and
hand-start it once: the first `pm2 reload` always fails because there is no process yet.

Open the `Malipopay/PLANS.md` block in the same push as the first pull request.

---

## Definition of done for phase 1

Not "it compiles". All five:

1. `GET /api/v1/banking/products` answers through `core-uat` with real data from the UAT
   Fineract, observed in a terminal.
2. The internal surface answers 404 at the gateway, against a control path that answers 403.
3. The concurrent-instruction test passes, and was seen to fail before the idempotency guard
   was added.
4. `deploy/scripts/proof.sh uat` passes against the same Fineract instance.
5. A deactivated user's existing token is refused.
