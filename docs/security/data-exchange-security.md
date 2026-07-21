# Security Guidelines for Data Exchange

Applies to every integration in the business-edge estate. Written as a
baseline an architecture review can be assessed against, not as aspiration.

---

## 1. Authentication by channel

| Channel | Mechanism | Rationale |
|---|---|---|
| SII (Acquirente Unico) | **mTLS**, client certificate issued at accreditation | The counterparty must be able to prove which Seller submitted a regulated request. Bearer tokens do not provide non-repudiation. |
| Distributors (where direct) | **mTLS** | Same argument. |
| Salesforce, Billing/MDM | **OAuth2 client credentials** | Machine-to-machine, short-lived tokens, central rotation, no long-lived shared secrets in runtime memory. |
| B2C / B2B portals | **OAuth2 authorization code + PKCE** | User-delegated access. PKCE because the B2C portal is a public client. |
| Partner / aggregator APIs | **OAuth2 client credentials + client-id enforcement** at the gateway | Per-partner throttling and revocation without redeployment. |

**Never used:** API keys as a sole authentication factor; HTTP Basic;
credentials in query strings.

---

## 2. Transport

- TLS 1.2 minimum, TLS 1.3 preferred. TLS 1.0/1.1 disabled at the gateway.
- Certificate pinning for the SII connection; its CA chain is stable and the
  interface is regulated.
- Truststores hold only the CAs actually required. A truststore containing
  the full public CA bundle grants far broader trust than the estate needs.
- Certificate expiry monitored with alerting at 60, 30 and 7 days. Expired
  client certificates on a regulated interface are a compliance incident,
  and they always expire at an inconvenient moment.

---

## 3. Secret management

**The controlling rule: the decryption key never lives with the ciphertext.**

Encrypted property files (`*.secure.yaml`) are committed. The AES key that
decrypts them is supplied at deploy time from the CI secret store or a vault,
via `-Dmule.secure.key`.

Committing the key alongside the encrypted values — for example as a
`global-property` in a config file next to the properties it decrypts — makes
the encryption decorative. Anyone with repository read access holds both
halves. This is a common real-world misconfiguration and is treated here as a
review-blocking finding.

Additional controls:

- `.gitignore` blocks `*.secure.yaml`, `*.jks`, `*.p12`, `*.pem`, `*.key`.
  Only `.example` templates are tracked.
- Keystores and truststores are mounted at deploy time, never committed.
- Secret scanning runs in CI on every push and blocks the pipeline on a hit.
- Credentials rotate on a fixed schedule and immediately on any suspected
  exposure. Rotation is a runbook, not an incident-time improvisation.

---

## 4. Logging and audit

Two distinct concerns, deliberately separated.

**Audit logging** is a regulatory control. Every SII exchange is recorded
with its request id, timestamp, PDR, originating channel and operator. These
records must be producible for a regulator or ombudsman enquiry and are
retained per the Seller's retention policy.

**Diagnostic logging** is operational. Stack traces, downstream fault
strings, payload fragments.

Rules governing both:

- **Never log:** full fiscal codes, bank details, credentials, tokens,
  certificate private material.
- **Log at reduced precision:** PDR may be logged in full (it identifies a
  supply point, not a person); fiscal codes are logged only as a masked
  suffix where correlation demands it.
- **Never return downstream detail to a caller.** SII fault strings can carry
  infrastructure identifiers. The caller receives a sanitised message plus a
  `correlationId`; the detail goes to the log, and the two are joined during
  triage.
- **Correlation id on every log line and every error response.** Without it,
  reconstructing a single customer journey across four hops is guesswork.

---

## 5. Data protection

- **Minimisation in transit.** Integration layers forward the narrowest field
  set that satisfies the use case. Where a source system returns identity
  documents or full addresses that the consumer does not need, the mapping
  drops them rather than passing them through.
- **Purpose limitation.** Data acquired for a regulated process is not reused
  for marketing without a separate lawful basis.
- **Retention.** Correlation records carry a TTL exceeding the regulatory
  response window with margin, then expire. Audit records follow the
  retention policy independently.
- **Right to erasure** is honoured against the CRM as system of record;
  regulated audit records are retained under the legal-obligation basis and
  this asymmetry is documented rather than resolved silently.

---

## 6. Gateway policy baseline

Applied at API Manager, not in flow logic, so the policy set is auditable
independently of any deployment:

| Policy | Applied to | Setting |
|---|---|---|
| Client ID enforcement | All external-facing APIs | Mandatory |
| Rate limiting (SLA-based) | Partner and portal APIs | Per-tier |
| Spike control | All external-facing APIs | Protects against deadline-driven surges |
| JWT validation | Portal-facing APIs | Signature, issuer, audience, expiry |
| IP allowlisting | Partner APIs | Where the partner has stable egress |
| CORS | B2C portal APIs | Explicit origin list, never `*` |

---

## 7. Review checklist

An integration is not approved for production until every line is satisfied.

- [ ] No secret, key or certificate material in version control
- [ ] Decryption key supplied at runtime, not committed
- [ ] TLS 1.2+ enforced; truststore scoped to required CAs only
- [ ] mTLS on all regulated external interfaces
- [ ] OAuth2 scopes are least-privilege, not blanket
- [ ] Correlation id propagated on every hop
- [ ] Audit events emitted for every regulated exchange
- [ ] No PII or downstream detail in caller-facing error responses
- [ ] Certificate expiry monitoring configured
- [ ] Secret scanning active in CI
- [ ] Idempotency key on every state-changing downstream call
- [ ] DLQ configured with an operator triage runbook
