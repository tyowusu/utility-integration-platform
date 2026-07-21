# ADR-0005 — Idempotency and duplicate suppression

**Status:** Accepted
**Date:** 2026-04-29

## Context

Three sources of duplication threaten the switching process:

1. **Customer behaviour** — double-clicking submit on a portal.
2. **Client retries** — a portal retrying after a timeout, where the original
   request in fact succeeded.
3. **Queue redelivery** — at-least-once delivery means an outcome message can
   be delivered more than once.

Each has a distinct consequence. A duplicate SII submission is rejected by
SII and counts against the Seller's rejection statistics, which ARERA
monitors. A duplicate billing activation produces a duplicate charge to a
real customer.

## Decision

Idempotency is enforced at three points, with different mechanisms.

**1. Submission — business-key deduplication.**
Before submitting to SII, the process layer checks the correlation store for
an in-flight request keyed `PDR + effectiveDate`. If one exists, the existing
`requestId` is returned with status `ALREADY_SUBMITTED` and HTTP 200 rather
than 202.

The key is the *business* identity of the request, not a client-supplied
token. A customer clicking twice generates two different client tokens but
one business request. Deduplicating on a client token would not catch it.

**2. Downstream state changes — idempotency key.**
Every state-changing downstream call carries `Idempotency-Key`, derived from
the SII request id. Billing activation is the case that matters: queue
redelivery must not produce a second activation and a second bill.

**3. Outcome consumption — idempotent projection.**
CRM and billing updates are expressed as idempotent operations (`PATCH` to a
known record, activation guarded by its idempotency key) rather than
appends. Reprocessing the same outcome converges to the same state.

## Consequences

**`ALREADY_SUBMITTED` returns 200, not 409.** A duplicate submission is not a
client error — the client's intent is satisfied and the correct request is in
flight. Returning 409 would push portals into error-handling branches for a
successful outcome, and in practice would surface to the customer as a
failure when nothing failed.

**The correlation store becomes load-bearing for correctness**, not just
convenience. Its availability and TTL are correctness properties. It is
configured persistent for exactly this reason.

**Business-key deduplication has a deliberate limit.** A customer legitimately
requesting a *different* effective date for the same PDR is a distinct
request and is allowed through. SII will reject it if one is already in flight
— which is the correct authority for that decision, not us.

## Alternatives considered

**Client-supplied idempotency token only.** Rejected: does not catch a
double-click, which generates distinct tokens for one intent.

**Optimistic submission, rely on SII rejection.** Rejected: SII rejections
count against the Seller in commercial-quality reporting, and the customer
receives a confusing rejection for something that in fact succeeded.

**Distributed lock on PDR.** Rejected as heavier than needed: the correlation
store already provides the required read-check-write, and a lock introduces a
liveness failure mode on a regulated path.
