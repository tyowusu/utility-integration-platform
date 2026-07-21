# Integration Catalogue

Inventory of integrations in the business-edge estate, with ownership,
interaction style and regulatory basis. Maintained as the input to
architectural review and the standardisation backlog.

Implementation status in this repository: **✅ implemented**, **◐ contract
only**, **○ catalogued, not built**.

---

## Gas — regulated commercial processes

| ID | Integration | Style | Systems | Regulatory basis | Status |
|---|---|---|---|---|---|
| GAS-01 | Switching submission | Sync → async outcome | Portal/CRM → SII → Distributor | Delibera 77/2018/R/com | ✅ |
| GAS-02 | Switching outcome consumption | Async (queue) | SII → CRM, Billing | Delibera 77/2018/R/com | ✅ |
| GAS-03 | Switching status query | Sync | Portal/CRM → SII | Delibera 77/2018/R/com | ✅ |
| GAS-04 | Eligibility pre-flight | Sync | Portal → Process | Delibera 77/2018/R/com | ✅ |
| GAS-05 | Voltura (counterparty update) | Sync → async | CRM → SII | Delibera 77/2018/R/com, Allegato A | ◐ |
| GAS-06 | Contract termination | Async | CRM → SII | Delibera 77/2018/R/com, Allegato B | ◐ |
| GAS-07 | Last-instance services activation | Async | SII → CRM, Billing | Delibera 77/2018/R/com, Allegato B | ○ |
| GAS-08 | Metering data at supplier change | Batch | Distributor → SII → Billing | Delibera 77/2018/R/com, Allegato C | ○ |
| GAS-09 | Arrears — suspension request | Async | Billing → SII → Distributor | TIMG | ○ |
| GAS-10 | Arrears — reconnection | Async | Billing → SII → Distributor | TIMG | ○ |

---

## Water — regulated commercial processes

No switching process exists; see [ADR-0002](../adr/0002-regulated-process-scope-gas-vs-water.md).

| ID | Integration | Style | Systems | Regulatory basis | Status |
|---|---|---|---|---|---|
| WAT-01 | Meter reading acquisition | Batch | Field/AMR → Billing | ARERA water-service regulation | ○ |
| WAT-02 | Reading validation and estimation | Batch | Billing internal | ARERA water-service regulation | ○ |
| WAT-03 | Tariff application | Sync | Billing → MDM | ARERA tariff method | ○ |
| WAT-04 | Commercial quality tracking | Async | CRM → Reporting | ARERA commercial quality | ○ |
| WAT-05 | Arrears — suspension | Async | Billing → Field ops | ARERA water arrears regulation | ○ |

---

## Customer-facing platforms

| ID | Integration | Style | Systems | Status |
|---|---|---|---|---|
| PORT-01 | B2C switching journey | Sync | B2C portal → Experience API | ✅ |
| PORT-02 | B2B switching journey (bulk) | Sync + batch | B2B portal → Experience API | ◐ |
| PORT-03 | Customer notification dispatch | Async (queue) | Process → notification service | ✅ |
| PORT-04 | Self-service status tracking | Sync | Portal → Experience API | ✅ |
| PORT-05 | Document retrieval (bills, contracts) | Sync | Portal → DMS | ○ |
| PORT-06 | Identity and consent management | Sync | Portal → CRM | ○ |

---

## Master data and back office

| ID | Integration | Style | Systems | Status |
|---|---|---|---|---|
| MDM-01 | Contract lookup by PDR | Sync | Process → Salesforce | ✅ |
| MDM-02 | Switching record projection | Sync | Process → Salesforce | ✅ |
| MDM-03 | Supply activation | Sync (idempotent) | Process → Billing | ✅ |
| MDM-04 | CRM ↔ billing reconciliation | Batch | Salesforce ↔ Billing | ○ |
| MDM-05 | Supply-point registry sync from SII | Batch | SII → MDM | ○ |

---

## Standardisation observations

Findings from reviewing the catalogue as a whole — the output an
architectural review is expected to produce.

**1. Outcome consumption is duplicated in pattern across GAS-02, GAS-06,
GAS-07, GAS-09 and GAS-10.** All five are "consume regulated async outcome,
correlate, project to CRM and billing." They are candidates for a single
parameterised outcome-handling process API rather than five near-identical
implementations. *Recommendation: consolidate; est. 40% reduction in
outcome-path code.*

**2. Three distinct correlation strategies exist across the estate.** The
switching path uses `PDR + effectiveDate`; older integrations use a
database sequence; one uses the SII request id alone. *Recommendation:
standardise on business-key correlation, documented per process.*

**3. Batch processes have no shared error contract.** Sync APIs share the
global error handler; batch jobs each report failures differently, which
makes cross-process operational dashboards impossible. *Recommendation:
extend the error contract to batch.*

**4. Reference data is embedded rather than managed.** SII reason-code
translations live in DataWeave and require a deployment to change.
*Recommendation: externalise to a managed reference-data service.*

**5. Water processes are entirely uncatalogued in code.** The regulatory
inventory exists but no integration has been built against it. This is a
known gap, stated rather than hidden — a catalogue that only lists what
exists is an inventory, not an architecture.

---

## Sources

- [SII — Acquirente Unico](https://www.acquirenteunico.it/attivita/sistema-informativo)
- [Delibera 77/2018/R/com (ARERA)](https://www.arera.it/schede-tecniche/dettaglio/it/schedetecniche/18/077-18st)
- [ARERA — Testi integrati](https://www.arera.it/area-operatori/testi-integrati)
