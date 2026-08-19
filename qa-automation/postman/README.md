# Postman / Newman suite

The collection is checked in; **the secrets are not**. `client_secret` is
deliberately empty in every environment file, and is supplied at run time.

## Run locally

```bash
newman run switching-api.postman_collection.json \
  -e env.dev.postman_environment.json \
  --env-var "client_secret=$CLIENT_SECRET" \
  --env-var "base_url=$API_BASE_URL" \
  --reporters cli
```

## Run in CI

The `api-tests.yml` workflow does this, exporting a JUnit report so failures
appear against the pull request rather than only inside a build log:

```bash
newman run ... --reporters cli,junit --reporter-junit-export newman-results.xml
```

## Folder ordering is significant

Folders are numbered because Newman executes them in order and later requests
depend on earlier ones:

| Folder | Purpose | Safe against production? |
|---|---|---|
| `00 — Auth` | Obtains the bearer token used by everything after it | Yes |
| `10 — Eligibility` | Read-only regulatory calendar checks | Yes |
| `20 — Submit` | Transmits real switching requests; seeds `seededRequestId` | **No** |
| `30 — Status` | Reads the request seeded in folder 20 | No (depends on 20) |
| `40 — Gateway policies` | Anonymous and malformed-token probes | Yes |

For a production smoke run, restrict to the read-only folders:

```bash
newman run switching-api.postman_collection.json \
  -e env.prod.postman_environment.json \
  --folder "00 — Auth" --folder "10 — Eligibility" --folder "40 — Gateway policies"
```

Running folder 20 against production would transmit a genuine switching
request to the SII under the Seller's operator code. That is a regulated act
with a real counterparty, not a test — and it would count against the Seller
in ARERA commercial-quality reporting when it was subsequently cancelled.

## Why this exists alongside Karate

The two suites overlap on purpose. Karate is where the depth is; Postman is
what a portal developer can open, run, and use as living documentation of the
contract they are integrating against. A collection nobody outside the QA team
can run is worth less than one that is slightly redundant.
