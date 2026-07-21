# ADR-0002 — Separate regulated-process catalogues for gas and water

**Status:** Accepted
**Date:** 2026-03-18

## Context

The utility operates in both gas and integrated water services. An early
proposal modelled a single "commercial process" abstraction spanning both,
on the reasoning that a customer is a customer and a supply point is a
supply point.

That proposal does not survive contact with the regulation.

## Decision

Maintain **one shared integration platform** but **two distinct regulated
process catalogues**. Patterns, security baseline, error contract and
observability are common. The process inventory is not.

### Gas

Governed by ARERA under the TIVG (retail sales) and TIMG (arrears), with
flows exchanged through the SII:

- switching (cambio venditore)
- commercial counterparty update (voltura), subentro
- contract termination and last-instance services
- metering data at supplier change
- arrears, suspension and reconnection

### Water

Governed by ARERA under the water-service regulations. **There is no
switching process.** The integrated water service is a territorial monopoly
organised per ATO: there is no retail competition and therefore no supplier
to switch to. The SII does not cover water.

Water processes are:

- billing and regulated tariff application
- metering: reading acquisition, validation, estimation
- commercial quality: response-time standards and indemnities
- arrears: regulated suspension and reconnection

## Consequences

A shared canonical model covers customer, supply point, contract and
measurement. It does **not** attempt a shared "market process" abstraction,
because the two domains do not share one.

The cost is some duplication between the two catalogues where processes
rhyme — arrears exists in both, with different rules. That duplication is
accepted deliberately: a single parameterised abstraction over two different
regulatory regimes produces a model that is wrong for both and that no
domain expert can review.

The benefit is that a gas regulatory change cannot accidentally alter water
behaviour, and vice versa. In a regulated domain, that isolation is worth
more than the duplication costs.

## Note on this decision's origin

This ADR exists because the alternative is an attractive-sounding mistake.
"Unify the commercial processes across utilities" reads as good architecture
and is the kind of thing that survives a review by people who do not know the
sector. Writing down *why* it is wrong is more useful than silently not doing
it.

## Sources

- [ARERA — Testi integrati](https://www.arera.it/area-operatori/testi-integrati)
- [TIVG — Testo integrato delle attività di vendita al dettaglio di gas naturale](https://www.arera.it/fileadmin/allegati/docs/09/tivg.pdf)
