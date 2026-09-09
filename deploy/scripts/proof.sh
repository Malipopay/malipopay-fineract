#!/usr/bin/env bash
# Exercise the core banking API end to end and print what actually came back.
#
#   ./proof.sh local
#   CBS_BASE=https://fineract-uat.example CBS_USER=... CBS_PASS=... ./proof.sh uat
#
# This is the check that separates "the container is running" from "the core banking system
# works". It opens a real savings account, deposits into it twice with the same idempotency
# key, and asserts the second call was answered from the cache rather than posting a second
# credit. That duplicate-posting behaviour is the single most important property for a
# system that will be driven by payment callbacks, which do get redelivered.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV_NAME="${1:-local}"
resolve_env "$ENV_NAME"
decrypt_env

PORT="$(env_value FINERACT_HOST_PORT)"; PORT="${PORT:-8080}"
TENANT="${CBS_TENANT:-$(env_value FINERACT_TENANT_IDENTIFIER)}"
BASE="${CBS_BASE:-http://127.0.0.1:${PORT}}"
API="${BASE}/fineract-provider/api/v1"
USER="${CBS_USER:-mifos}"
PASS="${CBS_PASS:-password}"
STAMP="$(date -u +%Y%m%d%H%M%S)"
PASSED=0; FAILED=0

hdr=(-H "Fineract-Platform-TenantId: ${TENANT}" -H "Content-Type: application/json")
auth=(-u "${USER}:${PASS}")

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { PASSED=$((PASSED+1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAILED=$((FAILED+1)); printf '  FAIL  %s\n' "$*"; }
jqv()  { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

need curl; need jq

say "0. Environment"
echo "  base    ${BASE}"
echo "  tenant  ${TENANT}"
echo "  user    ${USER}"
echo "  image   $(docker inspect -f '{{.Config.Image}}' malipopay-cbs-fineract 2>/dev/null || echo 'not local')"
echo "  digest  $(docker inspect -f '{{index .RepoDigests 0}}' "$(docker inspect -f '{{.Config.Image}}' malipopay-cbs-fineract 2>/dev/null)" 2>/dev/null || echo n/a)"

say "1. Health"
H="$(curl -s "${BASE}/fineract-provider/actuator/health")"
[[ "$(jqv "$H" .status)" == "UP" ]] && ok "actuator/health is UP" || bad "health: ${H:0:200}"

say "2. Authentication and tenant context"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" "${hdr[@]}" "${API}/offices")"
[[ "$CODE" == "200" ]] && ok "GET /offices authenticated: 200" || bad "GET /offices: ${CODE}"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" "${API}/offices")"
[[ "$CODE" != "200" ]] && ok "unauthenticated request refused: ${CODE} (control)" \
                       || bad "unauthenticated request was ACCEPTED"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" -H "Content-Type: application/json" \
        -H "Fineract-Platform-TenantId: not-a-real-tenant" "${API}/offices")"
[[ "$CODE" != "200" ]] && ok "unknown tenant refused: ${CODE} (control)" \
                       || bad "unknown tenant header was ACCEPTED"

OFFICES="$(curl -s "${auth[@]}" "${hdr[@]}" "${API}/offices")"
OFFICE_ID="$(jqv "$OFFICES" '.[0].id')"
echo "  head office id=${OFFICE_ID} name=$(jqv "$OFFICES" '.[0].name')"

say "3. Currency and savings product"
curl -s -X PUT "${auth[@]}" "${hdr[@]}" -d '{"currencies":["TZS","USD"]}' "${API}/currencies" >/dev/null
CUR="$(curl -s "${auth[@]}" "${hdr[@]}" "${API}/currencies" | jq -r '.selectedCurrencyOptions[].code' 2>/dev/null | tr '\n' ' ')"
[[ "$CUR" == *TZS* ]] && ok "TZS enabled (${CUR% })" || bad "TZS not in selected currencies: ${CUR}"

PROD_BODY=$(cat <<JSON
{ "name": "Malipo Everyday Savings ${STAMP}",
  "shortName": "S${STAMP: -3}",
  "description": "Proof product, retail savings",
  "currencyCode": "TZS",
  "digitsAfterDecimal": 2,
  "locale": "en",
  "nominalAnnualInterestRate": 3.5,
  "interestCompoundingPeriodType": 1,
  "interestPostingPeriodType": 4,
  "interestCalculationType": 1,
  "interestCalculationDaysInYearType": 365,
  "accountingRule": 1 }
JSON
)
P="$(curl -s -X POST "${auth[@]}" "${hdr[@]}" -d "$PROD_BODY" "${API}/savingsproducts")"
PRODUCT_ID="$(jqv "$P" .resourceId)"
[[ -n "$PRODUCT_ID" && "$PRODUCT_ID" != "null" ]] && ok "savings product created id=${PRODUCT_ID}" \
  || { bad "savings product: ${P:0:400}"; die "cannot continue without a product"; }

say "4. Customer and account"
TODAY="$(date -u +'%d %B %Y')"
CLIENT_BODY=$(cat <<JSON
{ "officeId": ${OFFICE_ID},
  "firstname": "Proof",
  "lastname": "Customer${STAMP: -4}",
  "legalFormId": 1,
  "active": true,
  "activationDate": "${TODAY}",
  "dateFormat": "dd MMMM yyyy",
  "locale": "en" }
JSON
)
C="$(curl -s -X POST "${auth[@]}" "${hdr[@]}" -d "$CLIENT_BODY" "${API}/clients")"
CLIENT_ID="$(jqv "$C" .clientId)"
[[ -n "$CLIENT_ID" && "$CLIENT_ID" != "null" ]] && ok "client created id=${CLIENT_ID}" \
  || { bad "client: ${C:0:400}"; die "cannot continue without a client"; }

ACC_BODY=$(cat <<JSON
{ "clientId": ${CLIENT_ID}, "productId": ${PRODUCT_ID},
  "submittedOnDate": "${TODAY}", "dateFormat": "dd MMMM yyyy", "locale": "en" }
JSON
)
A="$(curl -s -X POST "${auth[@]}" "${hdr[@]}" -d "$ACC_BODY" "${API}/savingsaccounts")"
ACCOUNT_ID="$(jqv "$A" .savingsId)"
[[ -n "$ACCOUNT_ID" && "$ACCOUNT_ID" != "null" ]] && ok "savings account created id=${ACCOUNT_ID}" \
  || { bad "account: ${A:0:400}"; die "cannot continue without an account"; }

for cmd in approve activate; do
  R="$(curl -s -X POST "${auth[@]}" "${hdr[@]}" \
      -d "{\"${cmd}dOnDate\":\"${TODAY}\",\"dateFormat\":\"dd MMMM yyyy\",\"locale\":\"en\"}" \
      "${API}/savingsaccounts/${ACCOUNT_ID}?command=${cmd}")"
  [[ "$(jqv "$R" .savingsId)" == "$ACCOUNT_ID" ]] && ok "account ${cmd}d" || bad "${cmd}: ${R:0:300}"
done

say "5. Payment type"
# Savings transactions require paymentTypeId. Fineract seeds three ("Money Transfer" and two
# adjustment types); a real deployment wants its own, so the money trail names the rail.
PT="$(curl -s "${auth[@]}" "${hdr[@]}" "${API}/paymenttypes")"
PAYMENT_TYPE_ID="$(printf '%s' "$PT" | jq -r '[.[] | select(.name=="Malipopay rail")][0].id // empty')"
if [[ -z "$PAYMENT_TYPE_ID" ]]; then
  R="$(curl -s -X POST "${auth[@]}" "${hdr[@]}" \
      -d '{"name":"Malipopay rail","description":"Funds moved by a Malipopay payment rail","isCashPayment":false,"position":1}' \
      "${API}/paymenttypes")"
  PAYMENT_TYPE_ID="$(jqv "$R" .resourceId)"
fi
[[ -n "$PAYMENT_TYPE_ID" && "$PAYMENT_TYPE_ID" != "null" ]] \
  && ok "payment type id=${PAYMENT_TYPE_ID}" || { bad "payment type: ${PT:0:300}"; die "no payment type"; }

say "6. Deposit, and the same deposit replayed"
IDEM="proof-funding-${STAMP}-0001"
DEP_BODY="{\"transactionDate\":\"${TODAY}\",\"transactionAmount\":100000,\"paymentTypeId\":${PAYMENT_TYPE_ID},\"dateFormat\":\"dd MMMM yyyy\",\"locale\":\"en\"}"

R1="$(curl -s -D /tmp/h1.$$ -X POST "${auth[@]}" "${hdr[@]}" -H "Idempotency-Key: ${IDEM}" \
      -d "$DEP_BODY" "${API}/savingsaccounts/${ACCOUNT_ID}/transactions?command=deposit")"
TXN1="$(jqv "$R1" .resourceId)"
[[ -n "$TXN1" && "$TXN1" != "null" ]] && ok "deposit posted, cbsTransactionId=${TXN1}" \
  || { bad "deposit: ${R1:0:400}"; die "the replay assertions are meaningless unless the first call succeeded"; }

R2="$(curl -s -D /tmp/h2.$$ -X POST "${auth[@]}" "${hdr[@]}" -H "Idempotency-Key: ${IDEM}" \
      -d "$DEP_BODY" "${API}/savingsaccounts/${ACCOUNT_ID}/transactions?command=deposit")"
TXN2="$(jqv "$R2" .resourceId)"
CACHED="$(grep -i '^x-served-from-cache:' /tmp/h2.$$ | tr -d '\r' | awk '{print tolower($2)}')"
echo "  replay status $(head -1 /tmp/h2.$$ | tr -d '\r')  x-served-from-cache: ${CACHED:-<absent>}"
[[ "$TXN2" == "$TXN1" ]] && ok "replay returned the ORIGINAL transaction id, no second credit" \
                         || bad "replay produced a different transaction: ${TXN1} then ${TXN2}"
[[ "$CACHED" == "true" ]] && ok "x-served-from-cache: true on the replay" \
                          || bad "replay did not carry x-served-from-cache (got '${CACHED:-absent}')"

# Worth knowing: the idempotency cache stores the FIRST response whatever it was. A request
# that failed validation is replayed as that same failure, so a corrected retry must carry a
# NEW key. The middleware mints one key per instruction, never per attempt.
BAL="$(curl -s "${auth[@]}" "${hdr[@]}" "${API}/savingsaccounts/${ACCOUNT_ID}" | jq -r '.summary.accountBalance')"
[[ "${BAL%%.*}" == "100000" ]] && ok "balance is ${BAL} after two identical calls" \
                                                 || bad "balance is ${BAL}, expected 100000"

say "7. Withdrawal"
W="$(curl -s -X POST "${auth[@]}" "${hdr[@]}" -H "Idempotency-Key: proof-payout-${STAMP}-0001" \
    -d "{\"transactionDate\":\"${TODAY}\",\"transactionAmount\":25000,\"paymentTypeId\":${PAYMENT_TYPE_ID},\"dateFormat\":\"dd MMMM yyyy\",\"locale\":\"en\"}" \
    "${API}/savingsaccounts/${ACCOUNT_ID}/transactions?command=withdrawal")"
WTXN="$(jqv "$W" .resourceId)"
[[ -n "$WTXN" && "$WTXN" != "null" ]] && ok "withdrawal posted id=${WTXN}" || bad "withdrawal: ${W:0:400}"
BAL="$(curl -s "${auth[@]}" "${hdr[@]}" "${API}/savingsaccounts/${ACCOUNT_ID}" | jq -r '.summary.accountBalance')"
[[ "${BAL%%.*}" == "75000" ]] && ok "balance is ${BAL}" || bad "balance is ${BAL}, expected 75000"

say "8. Statement"
TX="$(curl -s "${auth[@]}" "${hdr[@]}" "${API}/savingsaccounts/${ACCOUNT_ID}?associations=transactions")"
N="$(printf '%s' "$TX" | jq '[.transactions[]? | select(.reversed==false)] | length')"
[[ "$N" == "2" ]] && ok "statement carries exactly 2 transactions" || bad "statement carries ${N} transactions"
printf '%s' "$TX" | jq -r '.transactions[]? | "    \(.id)  \(.transactionType.value)  \(.amount)  \(.runningBalance // "-")"' 2>/dev/null | head -5

say "9. Surfaces that must NOT be open"
for path in actuator/env actuator/heapdump actuator/loggers; do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/fineract-provider/${path}")"
  [[ "$CODE" == "404" || "$CODE" == "401" ]] && ok "${path} is not exposed (${CODE})" \
                                             || bad "${path} answered ${CODE}"
done
CODE="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/fineract-provider/actuator/prometheus")"
echo "  actuator/prometheus ${CODE} (expected 200: metrics are deliberately exposed to the host)"

rm -f /tmp/h1.$$ /tmp/h2.$$
say "Result"
printf '  %d passed, %d failed\n\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
