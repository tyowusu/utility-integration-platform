# QA automation

Black-box API test automation for the Switching Experience API and the API
Manager gateway in front of it.

Full walkthrough: [`docs/guides/go-live-and-qa-automation.md`](../docs/guides/go-live-and-qa-automation.md).

## Why this is a separate Maven project

MUnit (in `../src/test/munit/`) tests the Mule application from the inside: it
mocks SII and Salesforce and asserts on flow behaviour. It cannot see the
gateway — policies are applied by API Manager *in front of* the application, so
from MUnit's vantage point they do not exist.

Everything here runs against a deployed URL, over the wire, through the gateway,
exactly as a portal would. That is the only position from which "is rate
limiting actually switched on in test?" is an answerable question.

## Layout

```
src/test/java/features/switching/   Karate — functional and regression
src/test/java/features/gateway/     Karate — policy enforcement
src/test/java/io/.../karate/        Karate JUnit 5 runners (three entry points)
src/test/java/io/.../restassured/   Schema conformance, JWT attacks, concurrency
src/test/java/io/.../support/       TestTokens — adversarial JWT minting
src/test/resources/schemas/         JSON Schema, derived from the RAML
src/test/resources/helpers/         Token fetch, seeding, load helpers
postman/                            Newman collection + environments
soapui/                             SoapUI / ReadyAPI — REST + SOAP end-to-end
jmeter/                             Peak-day load profile
```

## Three runner entry points, not one

| Entry point | Selects | Safe against production? |
|---|---|---|
| `SwitchingFunctionalTest#smoke` | `@smoke @readonly` | Yes |
| `SwitchingFunctionalTest#functional` | `@functional` (includes `@writes`) | **No** |
| `SwitchingFunctionalTest#gateway` | `@gateway` | Yes |

The split is structural rather than a matter of discipline. One suite would mean
either never running against production or running writes against it — and a
successful POST against production is a genuine regulated transmission to the
SII under the Seller's operator code, not a test.

## Running

```bash
# Read-only subset
mvn test -Dtest=SwitchingFunctionalTest#smoke \
  -Dkarate.env=dev \
  -Dapi.base.url=$API_BASE_URL_DEV \
  -Dtoken.url=$TOKEN_URL -Dclient.id=$CLIENT_ID -Dclient.secret=$CLIENT_SECRET

# Full functional (writes — dev/test only)
mvn test -Dtest=SwitchingFunctionalTest#functional -Dkarate.env=dev ...

# Gateway policies
mvn test -Dtest=SwitchingFunctionalTest#gateway -Dkarate.env=dev ... \
  -Dunapproved.client.id=$UNAPPROVED_ID -Dunapproved.client.secret=$UNAPPROVED_SECRET

# REST Assured integration suites (Failsafe)
mvn verify -Dapi.base.url=$API_BASE_URL_DEV -Daccess.token=$TOKEN

# JMeter peak-day profile
mvn verify -Pperf -Dapi.base.url=$API_BASE_URL_TEST -Dduration.seconds=300
```

Karate writes `target/karate-reports/karate-summary.html`. Open it.

## Fixtures are computed, never hardcoded

Every date is derived at run time from today. The pattern is *two months ahead,
first of the month* — inside the submission window on every calendar day,
because the deadline for month N+2 is day 10 of month N+1.

A suite containing `"2025-09-01"` passes for a few weeks and then fails
permanently for calendar reasons. The team learns that red is normal and misses
the next real failure. A fixture that expires is worse than no fixture.

Note the mid-month fixtures use `withDayOfMonth(15)`, not
`.replace("-01", "-15")` — the naive string replacement hits the *month* segment
of `2026-01-01` and produces `2026-15-01`, which is invisible for eleven months
of the year.

## Nothing secret is committed

`client_secret` is empty in every environment file. Credentials arrive as system
properties, populated from GitHub Actions secrets in CI and from the shell
locally.
