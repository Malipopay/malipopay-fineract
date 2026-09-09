# ADR 0003: which system owns which balance

**Status** accepted, 2026-09-09

## Problem

Malipopay already runs a double-entry ledger. Its phase 5 cutover moved every money-moving
event onto paired platform and merchant journals linked by a pair id, with sigma debits equal
to sigma credits enforced on write, and a nightly reconciliation identity that held across
all 55 tenants at zero drift.

Fineract has its own general ledger. Two double-entry systems with no ownership rule is the
single most expensive mistake available here: duplicated balances, reversals that only half
apply, and a reconciliation nobody can close. The feasibility assessment named it as the top
risk, and it is right.

## Decision

One authority per fact, written down and enforced by the code that posts.

| Fact | Authority | Why |
|---|---|---|
| Customer deposit and loan balances | Fineract | It is the product engine: interest, accrual, schedules, delinquency |
| Loan schedules, interest, allocations | Fineract | Duplicating this calculation is how the two systems drift |
| Float at operators and banks | Malipopay platform books | Malipopay holds the relationship and the reconciliation |
| Merchant payable, fees, commission, settlement | Malipopay platform books | Already live and reconciling |
| Payment lifecycle and provider status | Malipopay payments | Already the system of record for every rail |
| Mapping between the two | Banking middleware | So a second core banking system can be added without moving either |

The join is one new control account in the Malipopay platform books:
**`Customer Funds at CBS: FINERACT`**, a liability. Every credit posted to a customer account
in Fineract has a matching credit to that account, and every debit a matching debit.

The nightly identity: the sum of customer balances in Fineract equals the balance of
`Customer Funds at CBS: FINERACT`. It is the same shape as the identity already proven in
production between the merchant wallet and the merchant payable, which is the reason to trust
it: the mechanism is not new, only the account is.

## Posting rules

Every posting carries three references, and all three are persisted before the provider is
called: the Malipopay payment reference, the banking transaction id, and the core banking
transaction id. The banking transaction id is what becomes the `Idempotency-Key` on the
Fineract call.

One key per instruction, never per attempt. This matters more than it sounds: Fineract's
idempotency cache stores the first response whatever it was, including a validation failure,
and replays it with `x-served-from-cache: true`. A retry that reuses the key of a failed
attempt replays the failure forever. A corrected request gets a new key, and the old key
stays bound to the failure it caused.

Never mutate a historical financial record. Reversals and adjustments are new entries linked
to the original, in both systems.

## Revisit when

A second core banking system is added and holds customer balances at the same time, which
would need one control account per provider and a per-provider identity.
