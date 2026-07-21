# ADR-0004 — Regulatory rules as isolated, versioned DataWeave modules

**Status:** Accepted
**Date:** 2026-04-15

## Context

ARERA amends the regulated commercial processes regularly. Deadlines shift,
eligibility conditions change, tracciati are revised. Delibera 77/2018/R/com
itself explicitly defers to future provisions the definition of procedures
allowing switching on *any day of the month* — a change that, when it lands,
invalidates the current first-of-month rule outright.

An architecture for this domain must treat regulatory change as routine
rather than exceptional.

## Decision

Every regulated rule lives in a **dedicated DataWeave module** under
`src/main/resources/dwl/`, referenced by flows via `resource=`. Rules are
never inlined in flow XML.

Each module carries a header stating:

- the rule in plain language
- the resolution or specification it derives from
- a worked example
- any known pending change

## Consequences

**A regulatory amendment is a contained change.** When the switching window
rule changes, `validate-switching-request.dwl` and
`switching-eligibility.dwl` change. Flow logic does not. The test scope is
those modules and their consumers.

**Rules are reviewable by non-engineers.** A compliance or regulatory-affairs
colleague can read the module header and the rule expression and confirm it
matches their reading of the resolution. That review is impossible when the
rule is scattered across `choice` conditions in flow XML.

**Rules are unit-testable in isolation** with date-boundary cases — the 10th,
the 11th, month-end, leap years — without deploying an application.

**Cost: indirection.** Reading a flow no longer shows you the rule; you follow
a resource reference. Accepted, because the alternative optimises for the rare
act of reading a flow end-to-end over the frequent act of amending a rule
correctly.

## Implementation note

The SII tracciato mapping modules carry an explicit fidelity caveat: they
represent the *shape* of the regulated format, and any production
implementation must generate them against the current published
specification from Acquirente Unico and validate against the official XSD.
The specification is versioned and revised; a mapping module that does not
name its target version is a latent defect. This is recorded in the technical
debt register.

## Sources

- [Delibera 77/2018/R/com (ARERA)](https://www.arera.it/schede-tecniche/dettaglio/it/schedetecniche/18/077-18st)
- [SII portal — technical specifications, Acquirente Unico](https://www.acquirenteunico.it/attivita/sistema-informativo)
