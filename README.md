# Utility Integration Platform — ARERA-Regulated Switching Reference

A Mule 4 reference implementation of the Italian gas switching process
(*cambio venditore*), integrating a Seller's Salesforce CRM, billing/MDM,
B2B/B2C portals and the **SII** — the Sistema Informativo Integrato operated
by Acquirente Unico.

Accompanied by the architecture governance artefacts that belong with it:
ADRs, an integration catalogue, a security baseline and an operational KPI
definition.

---

## Why this repository exists

Integration architecture in a regulated utility is not primarily a technical
problem. The hard parts are that the rules change on the regulator's
schedule, that a lost message is a compliance failure rather than an
inconvenience, and that the domain contains traps which look like
generalisation opportunities until you know the sector.

This repository is built to demonstrate handling those three things, in code
and in the decisions recorded alongside it.

The implemented slice is switching, end to end. The wider estate is
catalogued rather than built — deliberately, since a catalogue that lists
only what exists is an inventory, not an architecture.

---

## The regulated process

Under **Delibera ARERA 77/2018/R/com**, gas switching moved exclusively into
the SII as of 1 November 2018. Two rules drive most of the implementation:

> The switching effective date must coincide with the **first day of the
> month**, and the request must be submitted by the **10th day of the
> preceding month**.

> Where the distribution user does not exercise revocation, the distributor
> transmits the admissibility flow within **1 working day** of the SII
> notification, and an inadmissibility flow within **2 working days**.

The first makes switching a *calendar-constrained* process. The second makes
it an *asynchronous* one. Together they shape the whole design.

```
   Customer            Platform                SII            Distributor
      │                    │                    │                   │
      │─── request ───────▶│                    │                   │
      │                    │── validate ARERA   │                   │
      │                    │   window locally   │                   │
      │                    │                    │                   │
      │                    │─── submit ────────▶│                   │
      │                    │◀── ack (reqId) ────│                   │
      │◀── 202 Accepted ───│                    │─── notify ───────▶│
      │                    │                    │                   │
      │                    │                    │◀── admissibility ─│
      │                    │◀── outcome (MQ) ───│    (1–2 wd)       │
      │                    │                    │                   │
      │                    │── correlate,       │                   │
      │                    │   update CRM +     │                   │
      │                    │   billing          │                   │
      │◀── notification ───│                    │                   │
```

The acknowledgement is **not** the outcome. Treating it as one — telling the
customer the switch succeeded when the distributor has not yet ruled — is the
most common defect in SII integrations, and the code comments say so where it
matters.

---

## Architecture

```
  B2C Portal   B2B Portal   Salesforce   Contact Centre
       └────────────┴────────┬───┴──────────────┘
                             │   OAuth2 + gateway policies
                    ┌────────▼─────────┐
                    │  EXPERIENCE      │  switching-eapi.xml
                    └────────┬─────────┘
                    ┌────────▼─────────┐      ┌────────────────┐
                    │  PROCESS         │◀────▶│  Anypoint MQ   │
                    │  regulated rules │ async│  outcomes, DLQ │
                    └────────┬─────────┘      └────────────────┘
         ┌───────────────────┼───────────────────┐
  ┌──────▼──────┐    ┌───────▼───────┐   ┌───────▼────────┐
  │  SYSTEM     │    │   SYSTEM      │   │    SYSTEM      │
  │  Salesforce │    │ Billing / MDM │   │  SII gateway   │
  │   OAuth2    │    │    OAuth2     │   │  mTLS + XML    │
  └─────────────┘    └───────────────┘   └────────────────┘
```

The boundary that earns its keep is **process ↔ system**. Regulatory change
lands in the process layer; vendor and protocol change lands in the system
layer. An ARERA resolution and a Salesforce API bump are then independent
changes with independent test scopes. See
[ADR-0001](docs/adr/0001-api-led-layering.md).

---

## What each part demonstrates

| File | Pattern |
|---|---|
| `experience/switching-eapi.xml` | Contract-first APIKit routing; one contract across four channels |
| `process/switching-process.xml` | Regulated validation, business-key idempotency, correlation-before-response |
| `process/switching-outcome-listener.xml` | Queue consumption, manual ack, NACK/DLQ, orphan routing |
| `system/sii-system-api.xml` | mTLS, regulated XML tracciato, audit logging as a control |
| `system/crm-billing-system-api.xml` | OAuth2 client credentials, idempotency keys on state changes |
| `global-error-handler.xml` | Uniform error contract; 422 for regulatory inadmissibility |
| `dwl/validate-switching-request.dwl` | The ARERA calendar rule, isolated and testable |
| `dwl/switching-eligibility.dwl` | Pre-flight calendar so portals disable unreachable dates |
| `dwl/canonical-to-sii-request.dwl` | Canonical → regulated tracciato, version-isolated |
| `dwl/sii-outcome-to-canonical.dwl` | Reason-code translation for two audiences at once |

---

## Governance artefacts

| Document | Contents |
|---|---|
| [Target architecture](docs/architecture/target-architecture.md) | Layer contracts, interaction styles, data-ownership rules, technical debt register |
| [Integration catalogue](docs/architecture/integration-catalogue.md) | Full estate inventory with standardisation findings |
| [Security guidelines](docs/security/data-exchange-security.md) | Auth per channel, secret management, audit vs diagnostic logging, review checklist |
| [KPIs and SLOs](docs/operations/kpi-and-slo.md) | Service levels, business KPIs, deadline-aware alerting, incident runbook |
| [ADR-0001](docs/adr/0001-api-led-layering.md) | API-led layering as default |
| [ADR-0002](docs/adr/0002-regulated-process-scope-gas-vs-water.md) | Why gas and water need separate process catalogues |
| [ADR-0003](docs/adr/0003-asynchronous-outcome-handling.md) | Queue-backed outcome handling |
| [ADR-0004](docs/adr/0004-regulatory-rules-as-versioned-modules.md) | Regulatory rules as isolated modules |
| [ADR-0005](docs/adr/0005-idempotency-and-duplicate-suppression.md) | Three-point idempotency strategy |

---

## Decisions worth a closer look

**Water has no switching process, and the architecture says so.**
The Italian integrated water service is a territorial monopoly per ATO — no
retail competition, no supplier to switch to, and the SII does not cover
water. A unified "commercial process" abstraction across gas and water sounds
like good architecture and is a domain error. [ADR-0002](docs/adr/0002-regulated-process-scope-gas-vs-water.md)
records why it was rejected rather than silently not done.

**The correlation record is written before the caller is told 202.**
If that write failed after the response, the asynchronous outcome would later
arrive with nothing to attach it to. Ordering makes the failure visible at
submission time, where it can be retried, instead of days later as an
orphaned regulated message. [ADR-0003](docs/adr/0003-asynchronous-outcome-handling.md)

**Duplicate submissions return 200, not 409.**
The client's intent is satisfied and the correct request is in flight.
Returning 409 pushes portals into error branches for a successful outcome.
[ADR-0005](docs/adr/0005-idempotency-and-duplicate-suppression.md)

**Local rejection rate is monitored, not targeted.**
Driving it down creates pressure to validate less, pushing rejections to SII
where they count against the Seller in ARERA commercial-quality reporting.
Treating a diagnostic as a target corrupts it. [KPIs](docs/operations/kpi-and-slo.md)

**The decryption key is never committed.**
`${mule.secure.key}` resolves at deploy time. Committing it next to the
encrypted properties it decrypts makes the encryption decorative — a common
real-world misconfiguration, treated here as a review-blocking finding.
[Security](docs/security/data-exchange-security.md)

---

## Specification fidelity — read before reusing

The SII tracciato mappings in `dwl/canonical-to-sii-request.dwl` and
`dwl/sii-outcome-to-canonical.dwl` follow the **shape** of the regulated XML
exchange. They are **not** a verbatim reproduction of the current
specification, and the reason codes are representative rather than
authoritative.

Acquirente Unico publishes the binding technical specification on the SII
portal and revises it periodically. Any production implementation must
generate these mappings against the current published version and validate
output against the official XSD before transmission.

This is stated plainly because a mapping module that silently claims more
fidelity than it has is a latent defect. It is also recorded in the technical
debt register.

---

## Running it

**Prerequisites** — JDK 17, Maven 3.9+, Anypoint Studio 7.17+ or Mule Runtime
4.6, an Anypoint Platform account for MQ.

SII access requires accreditation with Acquirente Unico and issued client
certificates; there is no public sandbox. Local runs target mocks.

```bash
git clone https://github.com/tyowusu/utility-integration-platform.git
cd utility-integration-platform

# Generates throwaway keystores and a plaintext local secrets file. The
# application builds its TLS context and resolves secure properties at
# startup — neither is lazy — so it cannot boot until these exist.
chmod +x scripts/bootstrap-local-dev.sh
./scripts/bootstrap-local-dev.sh

mvn clean test -Dmule.env=local -Dmule.secure.key=localdevkey12345
```

For a real deployment the secrets are encrypted rather than plaintext; see
`local.secure.yaml.example` for the Secure Properties Tool usage, and the
go-live guide below for how the key is injected by the pipeline.

Exercise the eligibility endpoint, which needs no downstream mock:

```bash
curl -k "https://localhost:8082/api/supply-points/12345678901234/eligibility"
```

Returns the regulatory calendar — which effective dates are reachable today
and when each window closes.

> Requires the MuleSoft EE repository for `ee:transform`. On Community
> Runtime, substitute `set-payload` with inline DataWeave; flow logic is
> unchanged.

---

## Deploying it live, and the QA automation around it

**→ [Go-live and QA automation guide](docs/guides/go-live-and-qa-automation.md)**

Step by step: Anypoint Studio → VS Code → Anypoint Platform (Exchange, API
Manager, CloudHub 2.0) → GitHub Actions → an API gateway test suite that proves
the policies are actually enforcing.

The pipeline builds the artifact once and promotes the same binary through dev,
test and production, with a manual approval and a deadline guard in front of
production. Test automation spans six tools, each with a stated reason for being
there:

| Layer | Tool | Sees the gateway? |
|---|---|---|
| Flow logic, mocked dependencies | MUnit | No |
| Scenario and regression | Karate | Yes |
| Schema conformance, JWT attacks, concurrency | REST Assured | Yes |
| Shareable collection, living documentation | Postman / Newman | Yes |
| REST + SOAP end-to-end | SoapUI / ReadyAPI | Yes |
| Peak-day load | JMeter | Yes |

The dividing line that matters: **MUnit cannot see the gateway.** It runs the
application in isolation and mocks its dependencies, while policies are applied
by API Manager in front of it. If autodiscovery fails to bind, the application
still starts and still serves traffic — ungoverned, with nothing in the logs to
say so. The first assertion in the gateway suite exists to catch exactly that.

---

## Repository layout

```
src/main/mule/
  global-config.xml                    connectors, mTLS, OAuth2, secure properties
  global-error-handler.xml             centralised error contract
  experience/switching-eapi.xml        channel-facing API
  process/switching-process.xml        regulated orchestration
  process/switching-outcome-listener.xml  async outcome consumption
  system/sii-system-api.xml            SII gateway
  system/crm-billing-system-api.xml    Salesforce and billing connectors

src/main/resources/
  api/switching-eapi.raml              API contract
  dwl/*.dwl                            regulatory rules and mappings
  properties/*.yaml                    environment configuration (local/dev/test/prod)

src/test/munit/
  switching-regulatory-rules-test-suite.xml   ARERA admissibility, idempotency
  switching-eligibility-test-suite.xml        regulatory calendar invariants

qa-automation/                         black-box suite (separate Maven project)
  src/test/java/features/switching/    Karate — functional and regression
  src/test/java/features/gateway/      Karate — policy enforcement
  src/test/java/io/.../restassured/    schema conformance, JWT attacks, throttling
  src/test/java/io/.../support/        TestTokens — adversarial JWT minting
  src/test/resources/schemas/          JSON Schema, derived from the RAML
  postman/                             Newman collection + environments
  soapui/                              SoapUI / ReadyAPI, REST + SOAP end-to-end
  jmeter/                              peak-day load profile

.github/workflows/
  ci-build.yml                         build, MUnit, coverage gate, spec lint
  cd-deploy.yml                        build once → Exchange → dev → test → prod
  api-tests.yml                        reusable QA workflow

scripts/bootstrap-local-dev.sh         throwaway keystores and local secrets

docs/
  guides/go-live-and-qa-automation.md  end-to-end deployment and QA guide
  architecture/                        target architecture, integration catalogue
  adr/                                 architecture decision records
  security/                            data exchange security baseline
  operations/                          KPIs, SLOs, incident runbook
```

---

## Background

**Theophilus Yaw Owusu** — Integration Engineer

Production MuleSoft experience across API-led design, DataWeave, Anypoint MQ,
API Manager policies, CloudHub deployment and CI/CD, delivered for a European
client in 2024.

This repository is original work written for demonstration. It contains no
proprietary code, client data or configuration from any employer or client.
The regulatory content is derived from publicly published ARERA and
Acquirente Unico material, cited below.

---

## Sources

- [Delibera 77/2018/R/com — Riforma del processo di switching nel mercato retail del gas naturale (ARERA)](https://www.arera.it/schede-tecniche/dettaglio/it/schedetecniche/18/077-18st)
- [SII — Sistema Informativo Integrato, Acquirente Unico](https://www.acquirenteunico.it/attivita/sistema-informativo)
- [ARERA — Testi integrati](https://www.arera.it/area-operatori/testi-integrati)
- [TIVG — Testo integrato delle attività di vendita al dettaglio di gas naturale](https://www.arera.it/fileadmin/allegati/docs/09/tivg.pdf)

---

## Licence

MIT — see [LICENSE](LICENSE).
