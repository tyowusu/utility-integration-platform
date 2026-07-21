# Target Integration Architecture — Business Edge

Scope: the integration estate between a gas and water utility's commercial
systems, its customer-facing channels, and the regulated external interfaces
it is obliged to exchange data with.

---

## 1. Context

```
   ┌──────────────┐   ┌──────────────┐   ┌──────────────────┐
   │  B2C Portal  │   │  B2B Portal  │   │  Contact Centre  │
   └──────┬───────┘   └──────┬───────┘   └────────┬─────────┘
          │                  │                    │
          └──────────────────┼────────────────────┘
                             │  OAuth2 + gateway policies
                    ┌────────▼─────────┐
                    │  EXPERIENCE APIs │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐        ┌──────────────────┐
                    │  PROCESS APIs    │◀──────▶│   Anypoint MQ    │
                    │  regulated rules │  async │  outcomes, DLQ   │
                    └────────┬─────────┘        └──────────────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
 ┌──────▼──────┐     ┌───────▼───────┐    ┌───────▼────────┐
 │ SYSTEM API  │     │  SYSTEM API   │    │   SYSTEM API   │
 │ Salesforce  │     │ Billing / MDM │    │  SII gateway   │
 │   OAuth2    │     │    OAuth2     │    │  mTLS + XML    │
 └──────┬──────┘     └───────┬───────┘    └───────┬────────┘
        │                    │                    │
 ┌──────▼──────┐     ┌───────▼───────┐    ┌───────▼────────┐
 │ Salesforce  │     │ Billing / MDM │    │  SII (Acq.Un.) │
 │     CRM     │     │               │    │  + Distributors│
 └─────────────┘     └───────────────┘    └────────────────┘
```

The SII is the single regulated interface through which sellers and
distributors exchange commercial-process flows. It was established at
Acquirente Unico under Law 129/2010 and mediates roughly 100 million flows a
year between 250+ distributors and 500+ sellers.

---

## 2. Layer responsibilities

| Layer | Owns | Explicitly does not own |
|---|---|---|
| **Experience** | Channel contracts, auth, parameter binding, channel-specific shaping | Business rules, downstream calls |
| **Process** | Regulated rules, orchestration, canonical model, idempotency | Vendor payload formats, transport concerns |
| **System** | One connector per external system, native payload translation | Business decisions, cross-system orchestration |

The boundary that matters most in this domain is between **process** and
**system**. Regulatory change lands in the process layer; vendor and protocol
change lands in the system layer. Keeping them separate means an ARERA
resolution and a Salesforce API version bump are independent, independently
testable changes.

---

## 3. Interaction styles, and when each applies

**Synchronous request/response** — portal reads, eligibility checks, status
queries. Chosen where the caller cannot proceed without the answer and the
answer is cheap.

**Asynchronous messaging** — every regulated outcome. Distributor
admissibility decisions arrive up to 2 working days after submission, so they
are inherently a separate transaction. Queue-backed rather than
webhook-to-HTTP because:

- outcome volume clusters around regulatory deadlines and must be absorbed,
  not shed;
- a lost outcome is a compliance failure, so redelivery and a DLQ are
  mandatory, not optional;
- downstream unavailability must not propagate back to the SII.

**Event notification** — customer notifications, CRM projections. Fire and
forget with at-least-once delivery; consumers are idempotent.

**Batch** — metering data acquisition and reconciliation. Volume-driven, no
interactive caller, runs on a schedule.

---

## 4. Domain scope: gas versus water

A distinction worth stating explicitly, because it is frequently got wrong.

**Switching does not exist for water.** The Italian integrated water service
is a territorial monopoly organised per ATO. There is no retail competition,
therefore no supplier to switch to, therefore no switching process, and the
SII does not cover water. Any architecture proposing a "water switching" flow
has misread the domain.

Water in this estate is:

- **billing and tariff application** — ARERA-regulated tariff structures
- **metering** — reading acquisition, validation, estimation
- **commercial quality** — response-time standards and indemnity obligations
- **arrears** — regulated suspension and reconnection procedures

The integration patterns are shared with gas; the regulated process catalogue
is not. Conflating the two produces a data model that fits neither.

---

## 5. Data quality and consistency

Three systems hold overlapping customer and supply-point data: Salesforce
(commercial relationship), billing/MDM (contractual and financial truth), and
the SII (regulatory truth for supply-point identity).

The rules applied here:

1. **The SII is authoritative for supply-point identity.** PDR, distributor
   and connection state are read, never asserted. Where local records
   disagree, local records are wrong.
2. **Billing/MDM is authoritative for contractual state.** Effective dates,
   tariffs and financial position.
3. **Salesforce is authoritative for the commercial relationship.** Consents,
   contact preferences, case history.
4. **No system writes to another's authoritative fields.** The integration
   layer projects, it does not arbitrate.

Reconciliation runs as a scheduled batch, reporting divergence rather than
auto-correcting it — silent correction of regulated data destroys the audit
trail that makes divergence explicable.

---

## 6. Technical debt register

Maintained as a live artefact, reviewed quarterly. Current entries in this
reference implementation:

| Item | Impact | Proposed remediation |
|---|---|---|
| SII tracciato mapping not pinned to a specification version | A specification revision breaks transmission silently | Pin version in module name; add XSD validation to the build |
| No circuit breaker on SII calls | Sustained SII outage exhausts worker threads during deadline peaks | Add Until-Successful with a circuit-breaker policy |
| Correlation store TTL fixed at 30 days | Long-running disputes may outlive the correlation record | Move to a queryable store with archival |
| Reason-code translations embedded in DataWeave | Text changes require a deployment | Externalise to a managed reference-data service |

Listing known debt is part of the architecture, not an admission against it.
An architecture document with no debt register is either new or not being
read.

---

## Sources

- [SII — Acquirente Unico](https://www.acquirenteunico.it/attivita/sistema-informativo)
- [Delibera 77/2018/R/com — Riforma del processo di switching nel mercato retail del gas naturale (ARERA)](https://www.arera.it/schede-tecniche/dettaglio/it/schedetecniche/18/077-18st)
- [ARERA — Testi integrati](https://www.arera.it/area-operatori/testi-integrati)
