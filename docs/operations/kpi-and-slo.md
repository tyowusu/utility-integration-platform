# Service Levels, KPIs and Incident Management

Covers availability, latency and error-rate monitoring for the business-edge
estate, and the escalation path when they are breached.

---

## 1. Service level objectives

| API | Availability | Latency (p95) | Latency (p99) | Error rate |
|---|---|---|---|---|
| Switching Experience API | 99.9% | 800 ms | 2 s | < 0.5% |
| Eligibility (pre-flight) | 99.9% | 300 ms | 800 ms | < 0.1% |
| Salesforce System API | 99.5% | 1.5 s | 4 s | < 1% |
| Billing System API | 99.5% | 2 s | 5 s | < 1% |
| SII gateway | 99.0% | 5 s | 30 s | < 2% |
| Outcome listener (queue) | 99.9% | n/a | n/a | < 0.1% |

**Why the SII targets are the loosest.** Its availability is not ours to
control, and its response times degrade around regulatory deadlines. Setting
an unachievable target for a dependency we do not operate produces alert
fatigue, which is worse than a realistic one.

**Why the eligibility endpoint is the tightest.** It sits in the customer's
interactive path before form submission. If it is slow, the form is slow, and
the journey is abandoned.

---

## 2. Business KPIs

Distinct from technical SLOs; these are what the commercial and compliance
functions ask about.

| KPI | Definition | Target | Why it is watched |
|---|---|---|---|
| Switching submission success rate | Accepted by SII ÷ submitted | > 98% | Sustained decline signals a data-quality or mapping defect |
| Local rejection rate | Rejected by our validation ÷ attempted | Monitored, not targeted | A *rise* is often good — catching more before SII sees them |
| Distributor admissibility rate | Admissible ÷ accepted by SII | > 95% | Falling rate points at CRM data quality, typically fiscal-code mismatch |
| Outcome processing lag | Queue arrival → CRM updated | p95 < 5 min | Customers check the portal after receiving a distributor notification |
| Orphaned outcome count | Outcomes with no correlation | 0 | Any non-zero value is a correctness defect, investigated individually |
| DLQ depth | Messages awaiting triage | 0 | Each message is a regulated outcome not yet actioned |

The local rejection rate is deliberately *monitored rather than targeted*.
Targeting it downward creates pressure to validate less, which pushes
rejections to SII where they count against the Seller. The metric is
diagnostic, and treating a diagnostic as a target corrupts it.

---

## 3. Deadline-aware alerting

The estate has a predictable monthly load profile: switching submissions
cluster ahead of the day-10 deadline, and outcomes cluster in the days after.

Alert thresholds are **calendar-aware**:

- **Days 1–10:** submission-path thresholds tightened. A SII outage here has
  a hard deadline attached — requests that miss the window slip a full month,
  which is a customer-visible commercial impact, not merely a technical one.
- **Days 11–end:** outcome-path thresholds tightened; submission volume is
  expected to be low and a spike is anomalous.

A flat threshold across the month either alerts constantly during the peak or
misses a genuine outage outside it.

---

## 4. Incident severity

| Sev | Definition | Response | Examples |
|---|---|---|---|
| **1** | Regulated obligation at risk | Immediate, 24/7 | SII unreachable during days 1–10; outcomes not processing; DLQ growing |
| **2** | Customer-facing degradation, no regulatory exposure | Within 1 hour, business hours | Portal eligibility check failing; CRM projection lagging |
| **3** | Internal degradation, no customer impact | Next business day | Elevated retries with successful eventual delivery |
| **4** | Cosmetic or informational | Backlog | Log noise, non-actionable warnings |

**The Sev-1 definition is regulatory, not technical.** A total outage of an
internal reporting API is not Sev-1. A partial failure to process switching
outcomes is, because a regulated outcome received and not actioned is a
compliance failure regardless of how few customers it touched.

---

## 5. Critical incident runbook — SII unavailable during submission window

1. **Confirm scope.** Distinguish SII outage from our egress failure —
   certificate expiry presents identically to an outage from the caller's
   side and is far more likely.
2. **Check certificate validity first.** It is the most common cause and the
   fastest to rule out.
3. **Assess deadline exposure.** How many days remain to day 10? How many
   requests are queued or failing?
4. **Communicate.** If the deadline is at risk, commercial and customer
   operations need to know before customers do.
5. **Queue rather than reject.** Submissions are held for retry rather than
   failed back to the customer, while the window remains open.
6. **Escalate to Acquirente Unico** through the accredited operator channel.
7. **Post-incident:** reconcile every held request; confirm none silently
   missed the window.

---

## 6. Observability requirements

Every integration must emit, without exception:

- **Correlation id** propagated across every hop and present on every log line
- **Business identifiers** — PDR, request id — on process-layer events
- **Audit events** for every regulated exchange, distinct from diagnostics
- **Queue depth and DLQ depth** as first-class metrics
- **Downstream latency** recorded per dependency, so a slow SII is
  distinguishable from a slow platform

An integration that cannot answer "what happened to this customer's switching
request?" from its telemetry alone is not production-ready, irrespective of
test coverage.
