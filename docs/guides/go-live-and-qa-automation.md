# Taking this platform live on Anypoint, and automating the QA around it

A working guide, start to finish: Anypoint Studio → VS Code → Anypoint Platform
→ GitHub Actions → an API gateway test suite that actually proves the policies
are on.

Everything referenced here exists in the repository. Where a step needs a value
only you can supply — an org ID, a Connected App secret — the guide says so and
tells you where to find it.

**Time to first deployed API:** about 2 hours if the Anypoint trial is already
active. The QA automation adds another 1–2 hours, mostly waiting on builds.

---

## Contents

1. [Before you start](#1-before-you-start)
2. [Anypoint Platform: the control-plane setup](#2-anypoint-platform-the-control-plane-setup)
3. [Anypoint Studio: run it locally](#3-anypoint-studio-run-it-locally)
4. [VS Code: the day-to-day editor](#4-vs-code-the-day-to-day-editor)
5. [Publish the API spec and create the governed instance](#5-publish-the-api-spec-and-create-the-governed-instance)
6. [Wire up GitHub](#6-wire-up-github)
7. [First deployment through the pipeline](#7-first-deployment-through-the-pipeline)
8. [The QA automation suite](#8-the-qa-automation-suite)
9. [Gateway policy testing — the part most people skip](#9-gateway-policy-testing--the-part-most-people-skip)
10. [Performance testing](#10-performance-testing)
11. [Troubleshooting](#11-troubleshooting)
12. [What this maps to on a job description](#12-what-this-maps-to-on-a-job-description)

---

## 1. Before you start

### Accounts and tooling

| Thing | Where | Notes |
|---|---|---|
| Anypoint Platform trial | [anypoint.mulesoft.com/login/signup](https://anypoint.mulesoft.com/login/signup) | 30 days. You have this already. |
| Anypoint Studio 7.x | [mulesoft.com/lp/dl/studio](https://www.mulesoft.com/lp/dl/studio) | Eclipse-based. Needed for the visual flow editor and the embedded runtime. |
| JDK 17 | Temurin | Mule 4.6+ runs on 17. Check with `java -version`. |
| Maven 3.9+ | `brew install maven` | `mvn -v` should report JDK 17. |
| VS Code | + Anypoint Code Builder extension | For editing, Git work, and DataWeave. |
| Node 20 | For Newman and the RAML linter | |
| `gh` CLI | Already authenticated as `tyowusu` | |

### Know your trial's limits before you design around them

A trial gives you Design Center, Exchange, one or two environments, API Manager,
and a small CloudHub allocation. Two things commonly surprise people:

- **vCore allocation is small.** The `dev` profile in `pom.xml` requests 0.1
  vCores and 1 replica precisely so a trial can run it. The `prod` profile asks
  for 2 replicas at 0.5 vCores — that will not deploy on a trial, and it should
  not: it exists to document the production shape.
- **Anypoint MQ may not be included.** The application declares an MQ config for
  the asynchronous outcome path. If MQ is unavailable on your tenant, the
  `switching-outcome-listener` flow will fail to start. Section 3 covers how to
  disable it for a local run.

### One thing that is not obtainable

The SII (Sistema Informativo Integrato, operated by Acquirente Unico) has **no
public sandbox**. Access requires accreditation as a Seller and issued client
certificates. Everything in this repository that touches SII therefore targets a
mock in dev and test, and the production property file carries
`REPLACE_FROM_ACCREDITATION_PACK` rather than a guess.

This is worth being explicit about rather than papering over. A demo that claims
a live regulated integration it does not have is worse than one that is precise
about where the boundary is.

---

## 2. Anypoint Platform: the control-plane setup

### 2.1 Find your organisation ID

Sign in → **Access Management** → **Organization**. Copy the ID (a UUID).

You will need it for `ANYPOINT_ORG_ID`. It appears in the Exchange Maven URL in
`pom.xml`'s `distributionManagement` block.

### 2.2 Confirm your environments

**Access Management → Environments.** A trial gives you `Sandbox` and
`Production`. The `pom.xml` profiles map:

| Profile | Anypoint environment | App name |
|---|---|---|
| `dev` | Sandbox | `switching-process-api-dev` |
| `test` | Sandbox | `switching-process-api-test` |
| `prod` | Production | `switching-process-api` |

`dev` and `test` share the Sandbox environment and are separated by app name.
On a paid tenant you would give each its own environment; on a trial this is the
honest compromise, and it is why the two have separate API Manager instances in
§5 — so a policy change in test cannot silently alter dev.

### 2.3 Create a Connected App

This is the credential the pipeline uses. **Access Management → Connected Apps →
Create app.**

- **Name:** `github-actions-switching-api`
- **Type:** *App acts on its own behalf (client credentials)*
- **Scopes:**
  - Design Center Developer
  - Exchange Contributor
  - Runtime Manager → *Cloudhub Admin*, *Create Applications*, *Manage Alerts* (Sandbox **and** Production)
  - API Manager → *Manage APIs Configuration*, *View APIs Configuration*
  - *Profile* and *View Organization*

Copy the **Client ID** and **Client Secret** immediately — the secret is shown
once.

> **Why a Connected App rather than a username and password.** A Connected App
> is scoped to exactly the environments and permissions the pipeline needs, can
> be revoked without touching anyone's account, and does not break the day
> someone enables MFA or leaves the company. A pipeline authenticating as a
> person is a pipeline that breaks at the worst possible moment for reasons
> unrelated to the code.

### 2.4 Find your CloudHub 2.0 target name

**You are not creating an application here.** The pipeline creates it, with the
name already set in `pom.xml`. All you need from this step is the name of the
deployment target, so the pipeline knows where to put it.

**Runtime Manager → Applications → Deploy application.** Look at the
**Deployment Target** dropdown. On a trial this is a shared space named
something like `Cloudhub-US-East-2` or `Cloudhub-EU-Central-1`. Copy that value
exactly, then **close the dialog without deploying**.

Update `ch2.target` in `pom.xml` to match. A wrong target name produces a
deployment failure whose message does not mention the target, which is an
unpleasant twenty minutes.

For reference, these are the applications the pipeline will create:

| Maven profile | Application name | Anypoint environment |
|---|---|---|
| `dev` | `switching-process-api-dev` | Sandbox |
| `test` | `switching-process-api-test` | Sandbox |
| `prod` | `switching-process-api` | Production |

If you do deploy by hand from this dialog — to sanity-check the platform before
trusting the pipeline, say — name it `switching-process-api-dev` so the first
pipeline run updates that application rather than creating a second one beside
it. There is no need to, though: the point of the pipeline is that the first
deployment is reproducible rather than a thing someone did once by hand and
then had to remember.

### 2.5 Anypoint MQ (optional on a trial)

If available: **MQ → Destinations**, create three queues per environment —
`switching-outcome-dev`, `customer-notification-dev`, `switching-manual-review-dev`
— then **MQ → Client Apps** to get a client ID and secret.

If unavailable, skip it and see §3.4.

---

## 3. Anypoint Studio: run it locally

### 3.1 Import the project

`File → Import → Anypoint Studio → Anypoint Studio project from File System`,
point at your clone, `Finish`.

Studio resolves dependencies from Exchange, so add your Connected App
credentials to `~/.m2/settings.xml` first:

```xml
<settings>
  <servers>
    <server>
      <id>anypoint-exchange-v3</id>
      <username>~~~Client~~~</username>
      <password>YOUR_CLIENT_ID~?~YOUR_CLIENT_SECRET</password>
    </server>
  </servers>
</settings>
```

The `~~~Client~~~` username and the `~?~` separator are literal. This is
MuleSoft's convention for Connected App credentials over Maven, and it is not
guessable.

### 3.2 Generate the local keystores

The application builds a TLS context at startup and resolves its secure
properties file at the same moment. Neither is lazy, so it cannot boot — and
therefore cannot run one MUnit test — until those files exist:

```bash
chmod +x scripts/bootstrap-local-dev.sh
./scripts/bootstrap-local-dev.sh
```

This produces self-signed certificates valid for a year, plaintext secure
properties, and passwords that are literally `changeit`. All of it is gitignored
and worthless by design.

The plaintext part is worth understanding: the secure properties module only
attempts decryption on values wrapped in `![...]` and passes anything else
through untouched. So a plaintext local file resolves with any key, which keeps
the local loop free of a key-management step while leaving the production
mechanism — encrypted values, injected key — exactly as it is.

### 3.3 Run

Right-click the project → `Run As → Mule Application`. Set VM arguments:

```
-Dmule.env=local -Dmule.secure.key=localdevkey12345
```

The API is at `https://localhost:8082/api`. Try:

```bash
curl -k https://localhost:8082/api/supply-points/12345678901234/eligibility
```

You should get the regulatory calendar. Note there is **no gateway** in front of
a Studio-launched runtime — no policies, no client-id enforcement. That is
expected, and it is exactly why the gateway suite in §9 exists as a separate
thing that only runs against a deployed app.

### 3.4 If Anypoint MQ is not available

Comment out the `anypoint-mq:config` element in
`src/main/mule/global-config.xml` and the flows in
`src/main/mule/process/switching-outcome-listener.xml`. The submit and
eligibility paths — everything the QA suite exercises — do not depend on MQ.

### 3.5 Run MUnit

Right-click `src/test/munit` → `Run MUnit suites`, or:

```bash
mvn clean test -Dmule.env=local -Dmule.secure.key=localdevkey12345
```

Coverage lives in `target/site/munit/coverage/`. The build fails below the
threshold set in `pom.xml`, which starts modest deliberately — a coverage gate
you cannot meet on day one gets switched off on day two. Ratchet it up as the
suite grows.

---

## 4. VS Code: the day-to-day editor

Studio is where you draw flows. VS Code is where you do everything else, and for
most days it is the better tool.

### 4.1 Extensions

- **Anypoint Extension Pack** (Salesforce) — Mule XML autocomplete, DataWeave
  language support, project scaffolding
- **Extension Pack for Java** (Microsoft) — for the REST Assured suite
- **Cucumber (Gherkin) Full Support** — for the Karate feature files
- **XML** (Red Hat) — schema validation on the Mule configs

### 4.2 Workspace settings

Create `.vscode/settings.json`:

```json
{
  "java.configuration.updateBuildConfiguration": "automatic",
  "files.associations": {
    "*.dwl": "dataweave",
    "*.feature": "gherkin"
  },
  "maven.terminal.useJavaHome": true,
  "editor.rulers": [100]
}
```

### 4.3 Tasks worth binding

`.vscode/tasks.json`:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Mule: build + MUnit",
      "type": "shell",
      "command": "mvn clean test -Dmule.env=local -Dmule.secure.key=localdevkey12345",
      "group": "test"
    },
    {
      "label": "QA: Karate smoke against dev",
      "type": "shell",
      "command": "cd qa-automation && mvn test -Dtest=SwitchingFunctionalTest#smoke -Dkarate.env=dev -Dapi.base.url=$API_BASE_URL_DEV",
      "group": "test"
    },
    {
      "label": "QA: Newman",
      "type": "shell",
      "command": "cd qa-automation/postman && newman run switching-api.postman_collection.json -e env.dev.postman_environment.json --env-var client_secret=$CLIENT_SECRET --insecure"
    }
  ]
}
```

### 4.4 The honest division of labour

Use Studio for: visual flow editing, the DataWeave preview pane (genuinely
excellent — live output against sample input), the embedded runtime debugger.

Use VS Code for: everything textual. The Mule XML is more legible as text than
as a canvas once you know what you are reading, Git conflicts in flow XML are
resolvable in a text editor and miserable in Studio, and the whole QA suite is
Java, JavaScript and Gherkin.

---

## 5. Publish the API spec and create the governed instance

This is the step that turns a running application into a *managed* API, and it
is where the gateway policies the job description asks about actually live.

### 5.1 Publish the RAML to Exchange

**Design Center → Create → Import from file**, upload
`src/main/resources/api/switching-eapi.raml`, name it
`Switching Experience API`, then **Publish to Exchange** as version `1.0.0`.

### 5.2 Create the API instance in API Manager

**API Manager → Add API → Add new API**:

- **Add from Exchange** → `Switching Experience API`
- **Runtime:** Mule 4
- **Deployment:** *Hybrid / Endpoint with proxy* → choose **Basic endpoint** with
  autodiscovery (no proxy — the policy runs inside your app's runtime)
- **Environment:** Sandbox

Once created, copy the **API Instance ID** from the URL or the summary panel.
This is `API_INSTANCE_ID_DEV`.

Repeat for test and production. Three instances, three IDs.

### 5.3 Understand what autodiscovery does — and how it fails

`src/main/mule/global-config.xml` contains:

```xml
<api-gateway:autodiscovery apiId="${api.id}" flowRef="switching-eapi-main"/>
```

At startup the runtime calls home to API Manager, says "I am instance
`${api.id}`", and downloads the policy set attached to it. From then on every
request through `switching-eapi-main` passes through those policies.

**The failure mode is silent.** If `api.id` is wrong, or the
`anypoint.platform.client_id`/`client_secret` pair was not supplied, or the app
is in a different environment from the instance, then the application *still
starts and still serves traffic* — ungoverned. No client-id enforcement, no rate
limiting, no JWT validation. Nothing in the logs announces this.

That is why the very first assertion in the gateway suite is "an anonymous
request must be refused". It reads like a security test; it is really an
autodiscovery health check.

### 5.4 Apply the policies

**API Manager → your instance → Policies → Add policy.**

| Policy | Configuration | Why |
|---|---|---|
| **Client ID enforcement** | Credentials in headers `client_id` / `client_secret` | Identifies which consumer — B2C portal, B2B portal, Salesforce — made each call. Under ARERA commercial-quality reporting the Seller must evidence request origin, so this is a compliance control, not just access control. |
| **OpenID Connect / JWT validation** | Your IdP's JWKS URL; validate `exp`, `aud`, signature | Machine-to-machine auth for the portals. Validate the signature *and* the audience — a policy that checks claims without verifying the signature accepts a forged token, and every happy-path test still passes. |
| **Rate limiting — SLA based** | Tiers per consumer | The portals and Salesforce have very different traffic shapes. One shared limit means the B2C portal's peak throttles the contact centre's agents. |
| **Spike control** | e.g. 20/sec, queuing enabled | Absorbs the 10th-of-the-month burst rather than rejecting it. Different intent from rate limiting: spike control smooths, rate limiting enforces a contract. |
| **HTTP caching** | On `GET /supply-points/{pdr}/eligibility`, short TTL | The regulatory calendar changes once a day at most. Every portal form load hits it. |

Set the **test** environment's rate limit low — say 20 requests per 10 seconds.
Section 9 explains why.

### 5.5 Create SLA tiers and register clients

**API Manager → instance → SLA tiers.** Create at least:

- `portal-tier` — 1000 req/min
- `salesforce-tier` — 200 req/min
- `qa-tier` — 30 req/min *(low on purpose, so CI can prove throttling works)*

Then **Exchange → your API → Request access**, creating a client application per
consumer. Each gets a client ID and secret. Create one deliberately **without**
an approved contract — that is `UNAPPROVED_CLIENT_ID`, used to prove that
client-id enforcement rejects an unregistered caller.

---

## 6. Wire up GitHub

### 6.1 Secrets

**Repository → Settings → Secrets and variables → Actions.**

| Secret | Where it comes from |
|---|---|
| `ANYPOINT_ORG_ID` | Access Management → Organization |
| `ANYPOINT_CONNECTED_APP_CLIENT_ID` | §2.3 |
| `ANYPOINT_CONNECTED_APP_CLIENT_SECRET` | §2.3 |
| `MULE_SECURE_KEY_DEV` / `_TEST` / `_PROD` | You generate these — 16 or 32 chars, one per environment |
| `ANYPOINT_PLATFORM_CLIENT_ID_DEV` / `_TEST` / `_PROD` | Access Management → Environments → *(env)* → client ID |
| `ANYPOINT_PLATFORM_CLIENT_SECRET_DEV` / `_TEST` / `_PROD` | Same screen |
| `API_INSTANCE_ID_DEV` / `_TEST` / `_PROD` | §5.2 |
| `API_BASE_URL_DEV` / `_TEST` / `_PROD` | Runtime Manager, after first deploy |
| `TOKEN_URL_DEV` / `_TEST` / `_PROD` | Your identity provider's token endpoint |
| `API_CLIENT_ID` / `API_CLIENT_SECRET` | §5.5, the QA-tier client |
| `UNAPPROVED_CLIENT_ID` / `UNAPPROVED_CLIENT_SECRET` | §5.5, the client with no contract |

Set them quickly with the CLI:

```bash
gh secret set ANYPOINT_ORG_ID --body "your-org-uuid"
gh secret set ANYPOINT_CONNECTED_APP_CLIENT_ID --body "..."
gh secret set ANYPOINT_CONNECTED_APP_CLIENT_SECRET --body "..."
```

Note the environment-scoped ones are *distinct per environment*. Using one
`MULE_SECURE_KEY` everywhere means a leaked dev key decrypts production
secrets — which is the whole mechanism, undone.

### 6.2 GitHub Environments

**Settings → Environments.** Create `dev`, `test`, `production`.

On `production`, add **required reviewers**. A production deployment here
transmits real requests to a regulated counterparty under the Seller's operator
code. That warrants a human.

### 6.3 The deadline guard

`cd-deploy.yml` refuses production deployments between the 8th and 11th of the
month. Days 8–11 straddle the ARERA submission deadline, when the following
month's switching requests cluster hard; a rolling restart during that window
drops submissions that cannot be retried tomorrow, because the window has
closed and the customer waits an extra month.

Override for a genuine incident fix by setting the repository variable
`OVERRIDE_DEADLINE_GUARD=true`. It should be a decision, not an accident.

---

## 7. First deployment through the pipeline

### 7.1 Push and watch

```bash
git add -A
git commit -m "Add CI/CD pipelines, MUnit suites and QA automation"
git push origin main
```

**Actions** tab. `CI — build and unit test` runs first, then `CD — publish,
deploy and verify`.

### 7.2 What happens, in order

```
build          → mvn verify (MUnit + coverage gate) → publish to Exchange
deploy-dev     → mvn deploy -DmuleDeploy -Pdev → poll until the app responds
verify-dev     → Karate smoke + full + gateway → Newman
deploy-test    → same artifact, -Ptest
verify-test    → full regression + JMeter peak-day profile
deploy-prod    → deadline guard → manual approval → deploy
verify-prod    → read-only smoke only
```

The artifact is built **once**. The same binary is promoted through every
environment. Rebuilding per environment is the most common route to running
something in production that no environment ever tested — a fresh dependency
resolution can pull a different patch of a connector, and nothing in the diff
shows it.

### 7.3 Capture the app URL

After `deploy-dev` succeeds, Runtime Manager shows the public URL. Add it as
`API_BASE_URL_DEV` and re-run — the verify jobs need it.

### 7.4 Deploy a single environment by hand

**Actions → CD — publish, deploy and verify → Run workflow**, pick the
environment. Useful when you want test without touching dev.

---

## 8. The QA automation suite

Four tools, deliberately overlapping, each earning its place.

### 8.1 What runs where

| Layer | Tool | Sees the gateway? | Location |
|---|---|---|---|
| Flow logic, mocked dependencies | **MUnit** | No | `src/test/munit/` |
| Scenario / regression | **Karate** | Yes | `qa-automation/src/test/java/features/` |
| Schema conformance, JWT attacks, concurrency | **REST Assured** | Yes | `qa-automation/src/test/java/io/github/portfolio/qa/restassured/` |
| Shareable collection, living documentation | **Postman / Newman** | Yes | `qa-automation/postman/` |
| REST + SOAP end-to-end | **SoapUI / ReadyAPI** | Yes | `qa-automation/soapui/` |
| Peak-day load | **JMeter** | Yes | `qa-automation/jmeter/` |

The dividing line that matters: **MUnit cannot see the gateway.** It runs the
application in isolation and mocks its dependencies. Policies are applied by API
Manager *in front of* the application, so from MUnit's vantage point they do not
exist. Everything else in the table runs over the wire against a deployed URL.

### 8.2 Run them locally

```bash
# MUnit — no deployment needed
mvn clean test -Dmule.env=local -Dmule.secure.key=localdevkey12345

cd qa-automation

# Karate: read-only subset (safe anywhere)
mvn test -Dtest=SwitchingFunctionalTest#smoke \
  -Dkarate.env=dev -Dapi.base.url=$API_BASE_URL_DEV \
  -Dtoken.url=$TOKEN_URL -Dclient.id=$CLIENT_ID -Dclient.secret=$CLIENT_SECRET

# Karate: full functional (writes — dev/test only)
mvn test -Dtest=SwitchingFunctionalTest#functional -Dkarate.env=dev ...

# Karate: gateway policies
mvn test -Dtest=SwitchingFunctionalTest#gateway -Dkarate.env=dev ...

# REST Assured integration suites
mvn verify -Dapi.base.url=$API_BASE_URL_DEV -Daccess.token=$TOKEN

# Newman
cd postman && newman run switching-api.postman_collection.json \
  -e env.dev.postman_environment.json --env-var "client_secret=$SECRET" --insecure
```

Karate writes an HTML report to `target/karate-reports/karate-summary.html`.
Open it — it is one of the better test reports in circulation.

### 8.3 Fixtures that do not expire

Every date in every suite is computed at run time relative to today. None is
hardcoded.

The pattern throughout is *two months ahead, first of the month*. That date is
inside the submission window on every calendar day, because the deadline for
month N+2 is day 10 of month N+1 — which has not arrived on any day of month N.

This is not fussiness. A suite with `"2025-09-01"` in it passes for a few weeks
and then fails permanently for calendar reasons. The team learns that red is
normal, and the next real failure goes unnoticed. A fixture that expires is
worse than no fixture.

The one test that *does* depend on today's date —
`closed-submission-window-is-rejected` — is conditionally skipped on or before
the 10th, because on those days the scenario it describes does not exist.
Skipping is honest. Rewriting the assertion so it passes on every date would
test nothing.

### 8.4 Read the suites for the reasoning

The test names and comments carry the argument, not just the mechanics. A few
worth reading:

- `duplicate-request-returns-200-not-a-second-sii-submission` — the assertion
  that matters is `verify-call ... times="0"`. Asserting only on the response
  body would pass even if a duplicate had been sent to SII and then discarded.
- `SwitchingContractIT.errorResponsesAreSanitised` — SII fault strings can carry
  hostnames and internal identifiers. They belong in the access-controlled audit
  log, not in a body that reaches a browser.
- `GatewaySecurityIT.forgedSignatureIsRefused` — unexpired, well-formed, correct
  claims, wrong signing key. A policy that reads claims without verifying the
  signature accepts this and passes every other test in the class.

---

## 9. Gateway policy testing — the part most people skip

This is the section the API QA Engineer role is really asking about, and it is
where most portfolios go quiet.

### 9.1 Why it needs its own suite

Three reasons policies go untested:

1. **They are invisible from inside.** MUnit mocks the world and runs the app
   directly. There is no gateway in the picture.
2. **Failure is silent.** If autodiscovery does not bind, the app runs fine and
   is simply ungoverned. No error, no warning, no log line.
3. **Proving a limit requires breaching it.** Nobody wants to breach a rate
   limit in an environment that matters — so the limit stays unproven.

### 9.2 The autodiscovery health check

`GatewaySecurityIT.anonymousRequestIsRefused` runs first, and its failure
message names the three usual causes:

```
Expected the gateway to refuse an anonymous request but got 200.
If this is 200, API Manager autodiscovery did not bind: check that api.id
matches the API instance in this environment and that
anypoint.platform.client_id/secret were supplied at deploy time.
```

A test that tells you what to go and look at is worth several that only tell you
something is wrong.

### 9.3 The JWT cases worth having

`TestTokens` mints tokens no legitimate issuer would produce:

| Token | Bypass it detects |
|---|---|
| `expired()` | Policy never checks `exp` |
| `forged()` | Policy reads claims without verifying the signature |
| `algNone()` | Library honours the header's algorithm choice — the classic bypass |
| `wrongAudience()` | Token minted for another API is accepted here |

All minted at call time, never checked in. A committed expired token stops being
interesting the moment someone asks "is this still expired?"; one built now with
a past `exp` is expired on every run, forever, and needs no upkeep.

### 9.4 Proving rate limiting

`GatewaySecurityIT.rateLimitIsEnforced` fires 60 concurrent requests through a
10-thread pool and asserts two things:

- at least one comes back **429**
- **none** comes back 5xx

The second is the one people forget. A throttled request must be refused
cleanly, because a 429 is something clients back off from and a 500 is something
they retry — and retrying is what deepens an overload rather than relieving it.

This is why the test environment's rate limit is set deliberately low (§5.4).
Proving a production-grade limit from a CI runner measures the runner, not the
gateway. A low limit in test proves the *mechanism* is wired up; capacity is a
separate question, answered in §10.

### 9.5 Writes never touch production

Enforced in three places, because one is not enough:

1. Feature files are tagged `@writes` / `@readonly`; the prod smoke selects
   `@readonly` only.
2. `cd-deploy.yml` calls `api-tests.yml` with `run_writes: false` for prod.
3. `api-tests.yml` hard-fails if `environment == prod && run_writes` — a guard
   against a manual dispatch with the wrong box ticked.

A successful POST against production is a genuine regulated transmission to the
SII under the Seller's operator code. Cancelling it afterwards still counts
against the Seller in ARERA commercial-quality reporting. This is not a case
where a stray test run is merely embarrassing.

---

## 10. Performance testing

### 10.1 The load profile models the 10th, not the average

`qa-automation/jmeter/switching-deadline-peak.jmx` has two thread groups:

- **TG1 — eligibility reads.** Highest volume, tightest budget (800ms). The
  portal calls this on every form load, so it sits directly in a page render.
- **TG2 — submissions.** Lower volume, far more expensive: traverses Salesforce
  and then SII over mutual TLS. Budget 3s, against a configured SII timeout of
  120s.

That 3s-versus-120s gap is deliberate. The runtime tolerates a slow SII so a
submission near the deadline still completes; the performance gate flags
degradation long before a customer would experience a timeout.

Modelling the average would answer a question nobody has. This platform is fine
for three weeks a month and then sees a multiple of its ordinary traffic in a
few hours. "Does the 10th hold?" is the question.

### 10.2 Run it

```bash
cd qa-automation
mvn verify -Pperf \
  -Dapi.base.url=$API_BASE_URL_TEST \
  -Djmeter.access.token=$TOKEN \
  -Dread.threads=50 -Dwrite.threads=10 -Dduration.seconds=300
```

HTML dashboard lands in `target/jmeter/reports/`.

### 10.3 What the CI numbers are and are not

A hosted GitHub runner is not a load generator. Treat these results as a
**regression signal** — "p95 moved 40% against last week's run" — not a capacity
statement. Sizing for the real peak needs distributed load from an environment
that resembles the actual callers, which is a separate exercise from this gate.

Saying so is better than presenting a runner-generated number as a capacity
finding.

---

## 11. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `401 Unauthorized` resolving dependencies | Exchange credentials missing or malformed | Check `~/.m2/settings.xml`. Username is literally `~~~Client~~~`; separator is literally `~?~`. |
| App starts locally, `Could not load keystore` | Bootstrap script not run | `./scripts/bootstrap-local-dev.sh` |
| MUnit fails at startup with a property error | `mule.secure.key` not supplied | Add `-Dmule.secure.key=localdevkey12345` |
| Deploy fails: *target not found* | `ch2.target` does not match your tenant | Copy the exact name from Runtime Manager → Deploy |
| Deploy succeeds, app crashes on start | `api.id` invalid or platform client ID/secret missing | Check `API_INSTANCE_ID_*` and `ANYPOINT_PLATFORM_CLIENT_*` secrets |
| **Gateway suite: anonymous request returns 200** | Autodiscovery did not bind | The app is ungoverned. Check `api.id` matches the instance *in this environment*, and that platform client ID/secret were passed at deploy. |
| Rate-limit test finds no 429 | Policy absent, or threshold above what CI can reach | Add SLA-based rate limiting to the test instance and set the QA tier low |
| Karate: connection refused right after deploy | CloudHub reports complete before the replica serves | The workflow's wait loop handles this; locally, give it 60–90s |
| Newman: `client_secret` undefined | Env file intentionally ships empty | Pass `--env-var "client_secret=$SECRET"` |
| Coverage gate fails on a fresh clone | Threshold above current suite coverage | Lower it in `pom.xml`, then ratchet up as tests are added |

---

## 12. What this maps to on a job description

For the API QA Engineer (MuleSoft) posting, point-by-point:

| Requirement | Where it lives |
|---|---|
| Test strategies for custom APIs and backend APIs behind a gateway | This document, §8–§10; the four-layer split in §8.1 |
| Functional, integration, regression, end-to-end across distributed systems | MUnit (`src/test/munit/`), Karate features, SoapUI end-to-end project |
| Validate auth/authz — OAuth2, JWT, API keys | `GatewaySecurityIT`, `TestTokens`, `features/gateway/api-gateway-policies.feature` |
| Request/response transformation, error handling, edge cases | Schema conformance in `SwitchingContractIT`; sanitisation and 422-vs-400 assertions throughout |
| Performance, reliability, scalability | `jmeter/switching-deadline-peak.jmx` with SLO assertions as build gates |
| Automation frameworks for API testing | `qa-automation/` — a standalone Maven project, environment-parameterised |
| Postman, REST Assured, Karate, SoapUI, ReadyAPI, JMeter | All six, each with a stated reason for being there rather than for the sake of the list |
| Integrate tests into CI/CD; reusable test data and mock services | `.github/workflows/api-tests.yml` as a reusable workflow; computed fixtures; Karate mock support |
| Validate gateway configuration — routing, rate limiting, security, transformation | §9 in full; policy setup in §5.4 |
| End-to-end across gateway, middleware, backend | SoapUI project spans REST experience layer and the SOAP/XML SII boundary |
| Troubleshoot integration issues across systems | §11; failure messages written to name the likely cause |
| CI/CD tooling — Jenkins, Azure DevOps, GitHub Actions, GitLab CI | GitHub Actions implemented here; the promotion model (build once, promote the binary) transfers unchanged |
| Java, Python, JavaScript | Java (REST Assured, JWT minting), JavaScript (Karate config, Postman scripts), Groovy (JMeter, SoapUI) |

The thing worth being able to talk about in an interview is not the tool list —
it is §9.2. Most candidates can describe a rate-limiting policy. Fewer can
explain that autodiscovery failure is silent, that an ungoverned application
looks identical to a governed one from the outside, and that the first
assertion in the suite exists to catch it.

---

## Appendix: file map

```
├── src/main/mule/                        Mule flows (experience / process / system)
│   └── global-config.xml                 + API Manager autodiscovery
├── src/main/resources/
│   ├── api/switching-eapi.raml           The contract
│   ├── dwl/                              Regulatory rule modules
│   └── properties/{local,dev,test,prod}.yaml
├── src/test/munit/                       MUnit — flow logic, mocked dependencies
│   ├── switching-regulatory-rules-test-suite.xml
│   └── switching-eligibility-test-suite.xml
├── qa-automation/                        Black-box suite (separate Maven project)
│   ├── src/test/java/features/           Karate: switching/ and gateway/
│   ├── src/test/java/io/.../restassured/ Contract + gateway security
│   ├── src/test/java/io/.../support/     TestTokens — adversarial JWTs
│   ├── src/test/resources/schemas/       JSON Schema, derived from the RAML
│   ├── postman/                          Collection + environments
│   ├── soapui/                           REST + SOAP end-to-end
│   └── jmeter/                           Peak-day load profile
├── .github/workflows/
│   ├── ci-build.yml                      Build, MUnit, coverage gate, spec lint
│   ├── cd-deploy.yml                     Build once → Exchange → dev → test → prod
│   └── api-tests.yml                     Reusable QA workflow
├── scripts/bootstrap-local-dev.sh        Throwaway keystores and local secrets
└── docs/
    ├── adr/                              Architecture decisions
    ├── architecture/
    ├── guides/go-live-and-qa-automation.md   ← you are here
    ├── operations/kpi-and-slo.md
    └── security/data-exchange-security.md
```
