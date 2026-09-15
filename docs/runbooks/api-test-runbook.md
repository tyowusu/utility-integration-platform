# API Test Runbook

My own notes for running the switching API test estate. Written in my words,
from things I have actually run — not copied from a guide.

---

## The loop — the same six questions for every tool

Before I touch any test tool, I answer these in order. If I cannot answer
one, *that* is what I look up — not the whole procedure.

| # | Question | What goes wrong if I skip it |
|---|---|---|
| 1 | **Target** — which environment, and what shape does this tool want the URL in? | 404s that look like a broken app (`/api/api/...`) |
| 2 | **Identity** — how does this tool get a token, and where must the secret *never* end up? | 401s; or a token written to a log, state file or shell history |
| 3 | **Scope** — which subset runs here, and what must not? | Writes against prod; a rate-limit burst throttling every other suite |
| 4 | **Run** — the command or button, and what its exit code means | "It finished" mistaken for "it passed" |
| 5 | **Read** — did it actually *execute*? How many requests / samples / assertions? | A green result that ran nothing (JMeter, a skipped Karate feature) |
| 6 | **Triage** — for each failure, which layer answered? | Fixing the test when the gateway was right, or the reverse |

## Triage — which layer answered?

Status code **and** body shape together. This platform's answers:

| Response | Layer | Usually means |
|---|---|---|
| `400 {"error": "JWT Token is required."}` | Gateway | No token sent |
| `401` | Gateway | Token malformed, expired, wrong signature, wrong `aud` |
| `403 {"error": "Authentication denied."}` | Gateway | Claim or contract problem (e.g. `azp`, no contract on *this* instance) |
| `429` | Gateway | Rate limit — **global per API instance**, not per client |
| bare `502` | Ingress | Can't reach the app (last-mile security config) |
| empty `503` | App | Autodiscovery not bound — wrong or placeholder `api.id` |
| `504` with `"code": "CONNECTIVITY"` | App → downstream | SII / Salesforce / billing host doesn't resolve — needs mocks |
| `422` with a reason | App | Business rule refused it — correct behaviour |
| body has `error.correlationId` | App | Only the application emits this; the gateway never does |
| green, but 0 requests / samples | **The test** | It didn't run. Never trust green without a count. |

## When I'm stuck — in this order, before asking anyone

1. This runbook.
2. The tool's own help: `newman run --help`, `mvn help:describe -Dplugin=... -Ddetail`, the tool's docs site.
3. The config file in the repo that the tool reads (collection, `.jmx`, `karate-config.js`, SoapUI project).
4. The error — which layer answered (table above)?
5. Then ask — and say which of 1–4 I already checked.

## Where the values live

| Value | Where |
|---|---|
| Dev host | `https://switching-process-api-dev-i6det0.5sc6y6-1.usa-e2.cloudhub.io` |
| Test host | `https://switching-process-api-test-azhcpt.5sc6y6-2.usa-e2.cloudhub.io` |
| Token URL | `https://dev-y07kpoe8c074nk6q.us.auth0.com/oauth/token` |
| Audience | `switching-experience-api` |
| QA client id / secret | Keychain: `uip-qa-client-id`, `uip-qa-client-secret` |
| Reading a secret without typing it | `security find-generic-password -a "$USER" -s <name> -w` |
| Anypoint trial / subscription expiry | UI: Access Management → Subscription. API: `GET /accounts/api/organizations/<org_id>` → `subscription.expiration` |

---

## Newman (Postman CLI) — worked example

**1 · Target.** `base_url` is the **host only**. Every request in the
collection already starts `{{base_url}}/api/...`. The committed env files hold
placeholders on purpose; I override with `--env-var` at run time.

**2 · Identity.** The `00 — Auth` folder mints the token itself from
`token_url`, `client_id`, `client_secret` and `audience`. Auth0 *requires*
`audience` on client-credentials — without it the token is for the wrong API
and the gateway answers 401. Secrets come from Keychain via `$(security ...)`,
never typed into the env file.

**3 · Scope.** Folders are chosen with `--folder`, matched by *exact* name —
em-dashes included. One wrong character fails the whole run with
`Invalid entrypoint`. `20 — Submit` and `30 — Status` need mocks.

**4 · Run.** `newman run <collection> -e <env file> --env-var "k=v" ... --folder '<name>' --insecure`.
Non-zero exit code means at least one assertion failed.

**5 · Read.** The summary table. My baseline against dev, all five folders:
**12 requests · 47 assertions · 7 failed**.

**6 · Triage.** All 7 failures are `504 CONNECTIVITY` from the submit and
status requests → downstream hosts don't resolve → mocks, not code.

---

## JMeter (GUI) — performance test

Plan: `qa-automation/jmeter/switching-deadline-peak.jmx`

**1 · Target.** Test Plan → *User Defined Variables* → `BASE_URL` is the
**host only**. The `GET eligibility` sampler adds the rest:
`${BASE_URL}/api/supply-points/<random 14 digits>/eligibility`. The random
PDR on every request stops caching from making the API look faster than it is.

**2 · Identity.** *HTTP Header Manager* sends
`Authorization: Bearer ${ACCESS_TOKEN}`, and `ACCESS_TOKEN` is
`${__P(access.token,)}` — set at launch with `-Jaccess.token=...`.
JMeter logs every `-J` value into `jmeter.log` in the directory it was
started from, so I launch from `$TMPDIR` with `-j` pointing there too.

**3 · Scope.** Reads only: disable *TG2 — Switching submissions* (needs
mocks). Size load against the rate limit, not against the plan: the limit is
**200/min, global per API instance**. From a laptop one thread at ~430ms is
~140/min — safe. Two threads is ~280/min → 429s → "Status is 200" fails, and
I'm measuring the limiter instead of the API. *Pace reads* targets 3000/min;
that's the peak-day ceiling, not something that protects a laptop run.

**4 · Run.** Clear previous results first (broom icon), then ▶ *Start*.
■ *Stop* kills threads immediately; *Shutdown* lets in-flight requests finish.

**5 · Read.** *Summary Report*: `# Samples` above zero proves the plan
executed. Then `Error %`, `Average` in ms against the 800ms SLO, and
`Throughput`.
Baseline — 2026-09-15, dev, JMeter 5.6.3 GUI, TG1 only, 1 thread, 20s, from laptop:
**52 samples · 0% errors · 381ms average · 2.6/s throughput** (≈156/min, under
the 200/min limit). Cross-checks: 52 ÷ 20s = 2.6/s, and 1000 ÷ 381 ≈ 2.62/s —
the numbers agree with each other, so the run is trustworthy.

CI baseline — 2026-09-15, dev, jmeter-maven-plugin 3.8.0 on a GitHub Actions
runner, TG1 only, 1 thread, 30s, paced at 60/min (run 35007839041, commit
1404c3d): **30 samples · 0% errors · 70ms average · 1.0/s throughput**.
Cross-check: 30 samples in 29s ≈ 1.0/s, matching the 60/min pacing. The 70ms
average against 381ms from the laptop is network distance, not a faster API —
compare CI runs with CI runs, laptop runs with laptop runs.

**6 · Triage.** `Error %` above zero → enable *View Results Tree* → click a
red sample → *Assertion result*. "Status is 200" failed → read the actual
code in *Response data* → triage table above. Only "SLO: under 800ms"
failed → latency, not correctness. Disable *View Results Tree* for real load:
it keeps every response in memory.
