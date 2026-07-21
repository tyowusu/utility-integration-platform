# ADR-0001 — API-led layering as the estate's default structure

**Status:** Accepted
**Date:** 2026-03-11

## Context

The estate integrates Salesforce CRM, billing/MDM, two customer portals, a
contact-centre desktop, and the SII. Before this decision, integrations were
built point-to-point: each channel called each backend directly, with
business rules duplicated per channel.

Two forces made that untenable. Regulatory change — an ARERA resolution
altering a deadline or eligibility condition — required locating and amending
the same rule in several places, with no guarantee they stayed consistent.
And adding a channel meant reimplementing orchestration that already existed.

## Decision

Adopt three-layer API-led connectivity as the default: experience, process,
system. Deviations require an ADR.

- **Experience** — one API per channel contract. Auth, binding, shaping.
- **Process** — regulated rules, orchestration, canonical model. Channel- and
  vendor-agnostic.
- **System** — one API per external system, in that system's native format.

## Consequences

**Accepted costs.** More deployable units and more network hops than
point-to-point. A trivial read now traverses three layers. This is a real
latency and operational cost, and it is the price of the containment below.

**What it buys.**

*Regulatory change has a predictable blast radius.* When ARERA amends the
switching window, the change is in one DataWeave module in the process layer.
Testing scope is that module and its consumers, not the estate.

*Vendor change is isolated.* A Salesforce API version bump touches one system
API. A billing platform replacement touches one system API.

*A new channel is cheap.* It reuses the process layer wholesale.

**Not adopted.** Universal layering for everything: a pure system-to-system
batch with a single consumer and no business rules does not gain from three
layers, and forcing it there is ceremony. Those exceptions are recorded as
ADRs rather than treated as violations.

## Alternatives considered

**Point-to-point with a shared library.** Rejected: shared libraries drift
across deployment cadences, and there is no runtime enforcement that every
consumer is on the current version of a regulated rule.

**Full ESB with centralised orchestration.** Rejected: the estate does not
need a single orchestration authority, and a central bus becomes a
change-management bottleneck. The regulated processes are better served by
autonomous process APIs with clear ownership.
