# ADR-0003 — Queue-backed handling of asynchronous SII outcomes

**Status:** Accepted
**Date:** 2026-04-02

## Context

Switching submission and its outcome are separate transactions. Under
Delibera 77/2018/R/com, where the distribution user does not exercise
revocation, the distributor transmits the admissibility flow within **1
working day** of receiving the SII notification, and an inadmissibility flow
within **2 working days**.

The submitting HTTP request cannot wait. A design is needed for receiving an
outcome that arrives hours or days later and reuniting it with its request.

## Decision

Outcomes are consumed from **Anypoint MQ**, correlated via a **persistent
object store** keyed on `PDR + effectiveDate`, and acknowledged manually
after successful processing.

The submission flow persists the correlation record **before** returning 202
to the caller.

## Consequences

**Ordering of the store and the response is load-bearing.** If the
correlation write failed after the caller had already been told 202, the
outcome would later arrive with nothing to attach it to and the request would
be orphaned — a compliance failure, since a regulated outcome would have been
received and not acted upon. Storing first makes the failure mode visible at
submission time, where it can be retried, rather than invisible days later.

**Manual acknowledgement.** The message is acknowledged only after CRM and
billing have been updated. A failure NACKs for redelivery. After the
configured attempts the broker moves it to a DLQ, where it is visible to
operations. Auto-acknowledgement would lose regulated messages on downstream
failure.

**Orphaned outcomes are routed, not dropped.** An outcome with no matching
correlation is acknowledged — redelivery cannot conjure a correlation that
does not exist — but republished to a manual-review queue. Silently
discarding a regulated message is not acceptable regardless of cause.

**TTL is a design parameter.** 30 days comfortably exceeds the regulatory
response window. It does not cover a months-long dispute; see the technical
debt register.

## Alternatives considered

**Inbound HTTP webhook from SII.** Rejected: outcome volume clusters heavily
around the monthly deadline, and an HTTP endpoint sheds load under spike
where a queue absorbs it. It would also propagate downstream unavailability
back to a regulated counterparty.

**Polling SII for status.** Rejected as the primary mechanism: it scales with
in-flight request count rather than outcome count, and adds latency between
outcome availability and customer notification. Retained as a *reconciliation*
mechanism — a scheduled sweep catches anything the queue path missed, which is
a genuine belt-and-braces need for regulated flows.

**Database table plus scheduled scan.** Rejected: reimplements a queue with
worse delivery semantics and no DLQ.

## Sources

- [Delibera 77/2018/R/com (ARERA)](https://www.arera.it/schede-tecniche/dettaglio/it/schedetecniche/18/077-18st)
