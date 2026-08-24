# Taking this platform live on Anypoint, and automating the QA around it

Start to finish: a local build, a governed API on CloudHub 2.0, a GitHub Actions
pipeline, and a test suite that proves the gateway policies are actually on.

**Read this first.** The steps are ordered so that each one produces something
the next one needs. Working out of order is the main way this goes wrong — most
obviously, the pipeline needs your deployed app's URL, which does not exist
until you have deployed once. So the first deployment is done by hand, and CI is
wired up afterwards with complete information.

**Time:** roughly 2 hours to a deployed, governed API. The QA automation adds
another 1–2, mostly waiting on builds.

---

## The order, at a glance

| # | Do this | You end up with | Which unblocks |
|---|---|---|---|
| **A. Prepare** ||||
| 1 | Install tooling, check the trial's limits | JDK 17, Maven, Studio, VS Code | everything |
| 2 | Anypoint: org ID, environments, Connected App | org UUID, client ID + secret | 3, 8, 11 |
| 3 | Maven `settings.xml` with Exchange credentials | working dependency resolution | every `mvn` command below |
| **B. Prove the code before touching the platform** ||||
| 4 | Clone, bootstrap keystores, `mvn test` | a green MUnit run | confidence that failures later are platform, not code |
| 5 | Run it in Anypoint Studio | the API on `localhost:8082` | 6 |
| 6 | Set up VS Code | your day-to-day editor | — |
| **C. Register the API with the platform** ||||
| 7 | Publish the RAML to Exchange | a versioned API asset | 8 |
| 8 | API Manager: one instance per environment, + policies, + SLA tiers | three **API instance IDs**, client credentials | 10, 11, 15 |
| 9 | Read the CloudHub 2.0 target name | `ch2.target` value for `pom.xml` | 10 |
| **D. Deploy once, by hand** ||||
| 10 | `mvn deploy -DmuleDeploy -Pdev` from your machine | **the app URL** | 11 |
| **E. Hand it to CI** ||||
| 11 | GitHub secrets (URL included) + environments | a fully configured pipeline | 12 |
| 12 | Push to `main` | green first run, dev → test → prod | 13 |
| **F. QA automation** ||||
| 13 | Run the functional suites | Karate, REST Assured, Newman results | — |
| 14 | Run the gateway policy suite | proof the policies bind and enforce | — |
| 15 | Run the JMeter peak-day profile | a performance regression baseline | — |

Everything referenced exists in the repository. Where a step needs a value only
you can supply, the guide says where to find it.

---

# Part A — Prepare

## 1. Tooling, and what the trial will and won't give you

### Install

| Thing | Where | Notes |
|---|---|---|
| Anypoint Platform trial | [anypoint.mulesoft.com/login/signup](https://anypoint.mulesoft.com/login/signup) | 30 days. You have this. |
| Anypoint Studio 7.x | [mulesoft.com/lp/dl/studio](https://www.mulesoft.com/lp/dl/studio) | Eclipse-based. For the visual flow editor and embedded runtime. |
| JDK 17 | Temurin | Mule 4.6+ runs on 17. `java -version` to check. |
| Maven 3.9+ | `brew install maven` | `mvn -v` must report JDK 17. |
| VS Code | + Anypoint Extension Pack | Editing, Git, DataWeave. |
| Node 20 | | For Newman and the RAML linter. |
| `gh` CLI | | Already authenticated as `tyowusu`. |

### Two trial limits that will bite

- **vCores are scarce.** The `dev` profile in `pom.xml` asks for 0.1 vCores and
  1 replica precisely so a trial can run it. The `prod` profile asks for 2
  replicas at 0.5 vCores — that will not deploy on a trial, and it should not.
  It exists to document the production shape.
- **Anypoint MQ may not be included.** The app declares an MQ config for the
  asynchronous outcome path. If MQ is unavailable, `switching-outcome-listener`
  fails to start. Step 5.4 covers disabling it.

### One thing you cannot get at all

The SII (Sistema Informativo Integrato, operated by Acquirente Unico) has **no
public sandbox**. Access requires accreditation as a Seller and issued client
certificates. Everything here that touches SII targets a mock in dev and test,
and `prod.yaml` carries `REPLACE_FROM_ACCREDITATION_PACK` rather than a guess.

Worth stating plainly rather than papering over. A demo claiming a live
regulated integration it does not have is worse than one that is precise about
where the boundary sits.

---

## 2. Anypoint: org ID, environments, Connected App

Do all three now — step 3 and everything after depends on them.

### 2.1 Organisation ID

**Access Management → Organization.** Copy the UUID.

This becomes `ANYPOINT_ORG_ID`, and appears in the Exchange Maven URL in
`pom.xml`'s `distributionManagement` block.

### 2.2 Environments

**Access Management → Environments.** Read the names that are actually there
and set `deploy.env` in each `pom.xml` profile to match. Two shapes are common:

| Profile | Three environments | Trial default | Application name |
|---|---|---|---|
| `dev` | `dev` | Sandbox | `switching-process-api-dev` |
| `test` | `test` | Sandbox | `switching-process-api-test` |
| `prod` | `prod` | Production | `switching-process-api` |

If you have three, take them — each gets its own API instance, its own client
provider association and its own environment credentials, so a policy change
in test cannot reach dev.

If dev and test share one Sandbox, they are separated only by application name.
That is the honest compromise on a constrained tenant, and it is why they still
get *separate API Manager instances* in step 8.

Either way the profiles must name environments that exist. `Sandbox` against an
organisation whose environment is called `dev` fails at deploy time with
`Couldn't find environmentName named [Sandbox]`.

While you are on this screen, copy each environment's **client ID and secret**
(shown per environment). These become `ANYPOINT_PLATFORM_CLIENT_ID_DEV` and
friends, and they are what lets a deployed app authenticate to API Manager for
autodiscovery. They are per-environment: an application deployed to test with
dev's credentials will not bind.

### 2.3 Connected App

This is the credential the pipeline uses. **Access Management → Connected Apps
→ Create app.**

- **Name:** `github-actions-switching-api`
- **Type:** *App acts on its own behalf (client credentials)*
- **Scopes:**
  - Design Center Developer
  - Exchange Contributor
  - Runtime Manager → *Cloudhub Organization Admin*, **_Cloudhub Network Administrator_**, *Create Applications*, *Read Applications*, *Manage Alerts*
  - API Manager → *Manage APIs Configuration*, *View APIs Configuration*
  - *Profile*, *View Organization*
- **Environments:** tick **every** environment the pipeline touches, using the
  names your organisation actually has.

Copy the **Client ID** and **Client Secret** now. The secret is shown once.

> **Use your real environment names.** A trial is often described as giving you
> `Sandbox` and `Production`, but an organisation may instead have `dev`, `test`
> and `prod` as three separate environments. Check **Access Management →
> Environments** and use what is there. Deploying to an environment name that
> does not exist fails with `Couldn't find environmentName named [Sandbox]`,
> which is at least clear — the same mismatch in a scope picker is not, because
> the scope simply never covers the environment you deploy to.
>
> Three separate environments is *better* than the shared-Sandbox compromise
> described in 2.2: a policy change in test genuinely cannot affect dev, and
> each gets its own API instance and client provider.

> **Cloudhub Network Administrator is not optional for CloudHub 2.0.** Without
> it the deployment fails at `GET .../targets/<target>/environments/<env>/domains`
> with a bare `403` naming a path and nothing else. The plugin calls that
> endpoint to resolve the public URL, and no other scope grants it — including
> Cloudhub Organization Admin. Nothing in the message suggests a permission is
> missing, so it reads as a platform fault rather than a configuration one.

> Only the Runtime Manager and API Manager scopes have an environment picker.
> Design Center, Exchange, Profile and View Organization are org-level. Miss an
> environment on the Runtime Manager scopes and everything works right up until
> you deploy to it, which fails with a 403 that does not mention scopes.

> **Why a Connected App and not a username and password.** It is scoped to
> exactly what the pipeline needs, revocable without touching anyone's account,
> and it does not break the day someone enables MFA or leaves. A pipeline
> authenticating as a person breaks at the worst possible moment, for reasons
> unrelated to the code.

---

## 3. Maven settings.xml

**Do this before any `mvn` command.** Anypoint Exchange is a private Maven
repository and the connectors this project depends on are not on Maven Central.
Without credentials, every build below fails at dependency resolution with a
401 that does not name the cause.

Create or edit `~/.m2/settings.xml`:

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

The `~~~Client~~~` username and the `~?~` separator are **literal**. That is
MuleSoft's convention for Connected App credentials over Maven, and it is not
something you would guess.

Verify before moving on:

```bash
cd utility-integration-platform
mvn -q dependency:resolve
```

Anything other than success here means step 2.3 or this file is wrong, and
fixing it now saves you debugging it inside a CI log later.

---

# Part B — Prove the code before touching the platform

The point of this part is diagnostic. If the code builds and its tests pass
locally, then every failure from Part C onward is a platform or configuration
problem — which is a much smaller search space.

## 4. Clone, bootstrap, test

```bash
git clone https://github.com/tyowusu/utility-integration-platform.git
cd utility-integration-platform

chmod +x scripts/bootstrap-local-dev.sh
./scripts/bootstrap-local-dev.sh

mvn clean test -Dmule.env=local -Dmule.secure.key=localdevkey12345
```

### What the bootstrap script is for

The application builds a TLS context at startup and resolves its secure
properties file at the same moment. Neither is lazy — so it cannot boot, and
therefore cannot run a single MUnit test, until those files exist on the
classpath.

The script produces self-signed certificates valid for a year, a plaintext
secure-properties file, and passwords that are literally `changeit`. All of it
is gitignored and worthless by design.

The plaintext part is worth understanding: the secure properties module only
attempts decryption on values wrapped in `![...]`, and passes anything else
through untouched. So a plaintext local file resolves with any key. That keeps
the local loop free of a key-management step while leaving the production
mechanism — encrypted values, injected key — exactly as it is.

### Expected result

MUnit runs, coverage lands in `target/site/munit/coverage/`. The build fails
below the threshold in `pom.xml`, which starts modest on purpose: a coverage
gate you cannot meet on day one gets switched off on day two. Ratchet it up as
the suite grows.

---

## 5. Anypoint Studio

### 5.1 Import

`File → Import → Anypoint Studio → Anypoint Studio project from File System`,
point at your clone, `Finish`. Studio reads the same `~/.m2/settings.xml` you
created in step 3, so dependency resolution should already work.

### 5.2 Run

Right-click the project → `Run As → Mule Application`. VM arguments:

```
-Dmule.env=local -Dmule.secure.key=localdevkey12345
```

Then:

```bash
curl -k https://localhost:8082/api/supply-points/12345678901234/eligibility
```

You should get the regulatory calendar back.

### 5.3 Note what is *not* here

There is **no gateway** in front of a Studio-launched runtime. No policies, no
client-id enforcement, no rate limiting. That is expected, and it is precisely
why the gateway suite (step 14) is a separate thing that only runs against a
deployed application. Nothing you do in Studio can tell you whether your
policies work.

### 5.4 If Anypoint MQ is unavailable

Comment out the `anypoint-mq:config` element in
`src/main/mule/global-config.xml` and the flows in
`src/main/mule/process/switching-outcome-listener.xml`. The submit and
eligibility paths — everything the QA suite exercises — do not depend on MQ.

---

## 6. VS Code

Studio is where you draw flows. VS Code is where you do everything else.

### 6.1 Extensions

- **Anypoint Extension Pack** (Salesforce) — Mule XML autocomplete, DataWeave
- **Extension Pack for Java** (Microsoft) — for the REST Assured suite
- **Cucumber (Gherkin) Full Support** — for the Karate feature files
- **XML** (Red Hat) — schema validation on the Mule configs

### 6.2 Workspace settings

`.vscode/settings.json`:

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

### 6.3 Tasks

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
    }
  ]
}
```

### 6.4 The honest division of labour

Studio for: visual flow editing, the DataWeave preview pane (live output against
sample input — genuinely excellent), the embedded runtime debugger.

VS Code for: everything textual. Mule XML reads better as text than as a canvas
once you know what you are looking at, Git conflicts in flow XML are tractable
in a text editor and miserable in Studio, and the entire QA suite is Java,
JavaScript and Gherkin.

---

# Part C — Register the API with the platform

## 7. Publish the RAML to Exchange

**Design Center → Create → Import from file.** Upload
`src/main/resources/api/switching-eapi.raml`, name it
`Switching Experience API`, then **Publish to Exchange** as version `1.0.0`.

### 7.1 Making the publish mean something

As shipped, the application reads the RAML from its own classpath:

```xml
<apikit:config name="switching-eapi-config" api="api/switching-eapi.raml" ... />
```

That builds anywhere, with no platform access — which is why the repository
ships that way. But it also means the Exchange copy and the implementation copy
are two files that a human keeps in step, which is exactly the coupling
API-led design is meant to remove.

Once Exchange has the asset, you can point the implementation at it instead.
Add the dependency to `pom.xml`:

```xml
<dependency>
  <groupId>YOUR_ORG_ID</groupId>
  <artifactId>switching-experience-api</artifactId>
  <version>1.0.0</version>
  <classifier>raml</classifier>
  <type>zip</type>
</dependency>
```

and change the APIkit config:

```xml
<apikit:config name="switching-eapi-config"
    api="resource::YOUR_ORG_ID:switching-experience-api:1.0.0:raml:zip:switching-eapi.raml"
    outboundHeadersMapName="outboundHeaders"
    httpStatusVarName="httpStatus" />
```

Now a spec change is a version bump in `pom.xml`, visible in a diff and
reviewable, rather than an edit two people make in two places and reconcile
later.

The trade-off is that the build then requires Exchange access, so a fresh clone
cannot compile offline. Both positions are defensible; make it deliberately.

---

## 8. API Manager: instances, policies, clients

This is where the gateway policies actually live, and where you collect the IDs
the deployment needs.

### 8.1 Create an instance per environment

**API Manager → Add API → Add new API**:

- **Add from Exchange** → `Switching Experience API`
- **Runtime:** Mule 4
- **Deployment:** *Endpoint with proxy* → choose **Basic endpoint** with
  autodiscovery. No proxy — the policies run inside your app's own runtime.
- **Environment:** Sandbox

Copy the **API Instance ID** from the URL or summary panel. That is
`API_INSTANCE_ID_DEV`.

**Repeat for test and production. Three instances, three IDs.** You need all
three before step 11.

### 8.2 What autodiscovery does, and how it fails silently

`src/main/mule/global-config.xml` contains:

```xml
<api-gateway:autodiscovery apiId="${api.id}" flowRef="switching-eapi-main"/>
```

At startup the runtime calls API Manager, says "I am instance `${api.id}`", and
downloads the policy set attached to it. From then on every request through
`switching-eapi-main` passes through those policies.

**The failure mode produces no error.** If `api.id` is wrong, or the
`anypoint.platform.client_id`/`client_secret` pair was not supplied, or the app
is in a different environment from the instance — the application *still starts
and still serves traffic*, ungoverned. No client-id enforcement, no rate
limiting, no JWT validation, and nothing in the logs to say so.

That is why the first assertion in the gateway suite is "an anonymous request
must be refused". It reads as a security test. It is really an autodiscovery
health check.

### 8.3 Apply the policies

**API Manager → your instance → Policies → Add policy.**

| Policy | Configuration | Why |
|---|---|---|
| **Client ID enforcement** | Credentials in headers `client_id` / `client_secret` | Identifies which consumer — B2C portal, B2B portal, Salesforce — made each call. Under ARERA commercial-quality reporting the Seller must evidence request origin, so this is a compliance control, not only an access control. |
| **OpenID Connect / JWT validation** | Your IdP's JWKS URL; validate `exp`, `aud`, signature; **set the Client ID Expression to match your IdP** | Validate the signature **and** the audience. A policy that reads claims without verifying the signature accepts a forged token — and every happy-path test still passes. |
| **Rate limiting — SLA based** | Tiers per consumer | Portals and Salesforce have very different traffic shapes. One shared limit means the B2C peak throttles the contact centre's agents. |
| **Spike control** | e.g. 20/sec, queuing enabled | Absorbs the 10th-of-the-month burst rather than rejecting it. Different intent from rate limiting: spike control smooths, rate limiting enforces a contract. |
| **HTTP caching** | On `GET /supply-points/{pdr}/eligibility`, short TTL | The regulatory calendar changes once a day at most, and every portal form load hits it. |

> **The JWT policy's Client ID Expression defaults to the wrong claim for
> Auth0.** It ships as `#[vars.claimSet.client_id]`, but an Auth0
> client-credentials token has no `client_id` claim — the client identifier is
> in `azp`, per the OIDC spec. `client_id` is an Okta and Azure AD convention.
>
> Left at the default the expression resolves to nothing, no client can be
> identified, and a perfectly valid token is refused with `403
> {"error": "Authentication denied."}` — which reads as a credentials problem
> rather than a claim-name mismatch. Decode a real token from your IdP and use
> whichever claim actually carries the client id:
>
> ```
> Client ID Expression:  #[vars.claimSet.azp]
> ```
>
> Note also that this policy performs contract validation itself, via
> **Skip Client Id Validation** and the expression above. A separate Client ID
> Enforcement policy is usually unnecessary — and would conflict with a suite
> that authenticates with a bearer token alone, since that policy expects
> `client_id`/`client_secret` headers.

Set the **test** instance's rate limit deliberately low — say 20 requests per
10 seconds. Step 14 explains why.

### 8.4 SLA tiers and client applications

**API Manager → instance → SLA tiers:**

- `portal-tier` — 1000 req/min
- `salesforce-tier` — 200 req/min
- `qa-tier` — 30 req/min *(low on purpose, so CI can prove throttling works)*

Then **Exchange → your API → Request access**, creating a client application per
consumer. Each yields a client ID and secret.

Create one client **without** an approved contract. That is
`UNAPPROVED_CLIENT_ID` — used to prove client-id enforcement rejects an
unregistered caller.

---

## 9. Find the CloudHub 2.0 target name

**You are not creating an application here.** Step 10 creates it, with the name
already set in `pom.xml`. All you need is the deployment target name.

**Runtime Manager → Applications → Deploy application.** Look at the
**Deployment Target** dropdown — on a trial this is a shared space named
something like `Cloudhub-US-East-2` or `Cloudhub-EU-Central-1`. Copy the value
exactly, then **close the dialog without deploying**.

Set `ch2.target` in `pom.xml` to match. A wrong target name produces a
deployment failure whose message does not mention the target, which is an
unpleasant twenty minutes.

---

# Part D — Deploy once, by hand

## 10. The first deployment

Do this from your machine, not from CI. It is what produces the application URL
that CI needs, and it isolates deployment problems from pipeline problems —
debugging both at once through a build log is miserable.

### 10.0 Five things that must be true before the command will work

None of these are visible from the command itself, and each fails with a
message that names a symptom rather than a cause. Get them right first.

**1. The environment-specific files must exist.** `bootstrap-local-dev.sh`
generates `local.secure.yaml` and the `local-*` keystores only. `dev.yaml`
references `properties/dev.secure.yaml`, `keystores/dev-keystore.jks` and
`truststores/dev-truststore.jks`, and none of them are created for you. All
three are gitignored, so a fresh clone has none of them and neither does CI.
Generate the dev set the same way the script does for local — same
`changeit` passwords, aliases `dev` and `seller-client-cert`.

Missing, they surface as `CrashLoopBackOff` with `Couldn't find resource:
properties/dev.secure.yaml neither on classpath or in file system`.

**2. `groupId` must be your organisation UUID.** Exchange rejects anything
else outright: *"The groupId 'io.github.portfolio' is invalid. It must be
your organization UUID"*. Since CloudHub 2.0 deploys *from* Exchange rather
than from an uploaded jar, this is not optional. The cost is that the
coordinate is organisation-specific and a fork must change it.

**3. Publish to Exchange first — this is a separate command.** CloudHub does
not upload your jar; it fetches a published Exchange asset. Deploying before
publishing fails with `404 ... Failed to retrieve artifact information from
Exchange. Reason: There is no asset matching given parameters`, which sounds
like a missing API rather than a missing publish.

```bash
mvn clean deploy -DskipTests -Danypoint.orgId=$ANYPOINT_ORG_ID
```

Note the absence of `-DmuleDeploy`. With it, the mule-maven-plugin deploys to
CloudHub; without it, `deploy` publishes to Exchange. Exchange versions are
immutable, so every republish needs a `<version>` bump — which is the point:
`1.0.0` and `1.0.1` are distinguishable artifacts rather than two builds
sharing a label.

**4. `api.id` must be forwarded to the deployed application.** Passing
`-Dapi.id=...` sets a *Maven* property. It reaches the running application
only if `cloudhub2Deployment` forwards it:

```xml
<properties>
    <mule.env>${mule.env}</mule.env>
    <anypoint.platform.client_id>${autodiscovery.clientId}</anypoint.platform.client_id>
    <api.id>${api.id}</api.id>
</properties>
```

Without it the application cannot resolve `${api.id}` in the autodiscovery
element and never starts. With a *wrong* value it starts and then fails its
readiness probe with `API <id>: Not Ready. API not found in the API
Platform` — worth reading carefully, because a mistyped instance id produces
exactly this and the id in the message is easy to skim past.

**5. Last-mile security must be nested under `http/inbound`.** The plugin
also accepts `lastMileSecurity` at the top level of `deploymentSettings`,
where it is silently ignored: the deployment spec then reports
`lastMileSecurity: true` while `http.inbound` stays empty, and CloudHub reads
the nested value. The application is healthy, `1/1` replicas are started,
nothing appears in its log, and every request returns a bare **502** from the
ingress.

```xml
<deploymentSettings>
    <http>
        <inbound>
            <lastMileSecurity>true</lastMileSecurity>
        </inbound>
    </http>
</deploymentSettings>
```

This is needed because the inbound listener is HTTPS with its own TLS
context. Otherwise CloudHub terminates TLS at the edge and forwards plaintext
to a socket expecting TLS. Do **not** also set `forwardSslSession` — a shared
space rejects it with `ForwardSslSession is not supported for the given
deployment target`; it requires a private space.

### 10.1 Deploy

```bash
mvn deploy -DmuleDeploy -Pdev \
  -DskipMunitTests \
  -DconnectedApp.clientId=$ANYPOINT_CLIENT_ID \
  -DconnectedApp.clientSecret=$ANYPOINT_CLIENT_SECRET \
  -Danypoint.orgId=$ANYPOINT_ORG_ID \
  -Dmule.secure.key=$MULE_SECURE_KEY_DEV \
  -Dautodiscovery.clientId=$ANYPOINT_PLATFORM_CLIENT_ID_DEV \
  -Dautodiscovery.clientSecret=$ANYPOINT_PLATFORM_CLIENT_SECRET_DEV \
  -Dapi.id=$API_INSTANCE_ID_DEV
```

Every one of those values came from steps 2 and 8.

`-DskipMunitTests` is there because MUnit boots a Mule EE runtime, which
resolves `com.mulesoft.licm:licm` from MuleSoft's private Nexus — a paid
support entitlement distinct from the Exchange credentials configured in step
3. Without it the deployment fails on a 401 for a licensing artifact rather
than on anything about the deployment. Run the suites in Anypoint Studio,
which uses its own bundled licensed runtime.

`scripts/deploy.sh` wraps all of this and reads the three secrets from the
macOS Keychain, so a redeploy is one command rather than a retyping exercise.

### 10.2 Confirm it deployed *and* bound

**Runtime Manager → Applications →** `switching-process-api-dev`. Copy the
public URL. Then:

```bash
# Should return 200 and the regulatory calendar
curl -k "$APP_URL/api/supply-points/12345678901234/eligibility" \
  -H "Authorization: Bearer $ACCESS_TOKEN"

# Should be refused — this is the autodiscovery check
curl -k -o /dev/null -w "%{http_code}\n" \
  "$APP_URL/api/supply-points/12345678901234/eligibility"
```

Read the second result carefully; it has four distinct meanings.

| Response | Meaning |
|---|---|
| **400** `{"error": "JWT Token is required."}` | Correct, and what a *missing* token actually returns — not the 401 you might expect. A malformed or unsigned token does return 401. Autodiscovery bound and policies are enforcing. |
| **401/403** | Also correct. |
| **200** | The app deployed but never bound. It is serving traffic **ungoverned**. Check `api.id` against the instance *in this environment* and confirm the platform client id and secret were passed. |
| **empty 503** | Autodiscovery bound to something that does not exist — typically a placeholder or mistyped `api.id`. The gatekeeper policy holds all traffic while waiting for a policy set that never arrives. Note this contradicts the "fails silently and serves ungoverned" description in 8.2: with a *nonexistent* instance it fails closed, not open. |
| **502** | The ingress cannot reach the application at all — a transport problem, not a policy one. See 10.0 point 5. The application will look healthy with `1/1` replicas started. |

Do not proceed until that second call is refused — every gateway test
downstream assumes it.

### 10.3 Keep the URL

You now have `API_BASE_URL_DEV`. Repeat step 10 with `-Ptest` and the test
credentials to get `API_BASE_URL_TEST`. Leave production for the pipeline.

---

# Part E — Hand it to CI

## 11. GitHub secrets and environments

You now have every value the pipeline needs — including the URLs, which is the
whole reason this step comes after step 10 rather than before it.

### 11.1 Secrets

**Repository → Settings → Secrets and variables → Actions.**

| Secret | From |
|---|---|
| `ANYPOINT_ORG_ID` | step 2.1 |
| `ANYPOINT_CONNECTED_APP_CLIENT_ID` | step 2.3 |
| `ANYPOINT_CONNECTED_APP_CLIENT_SECRET` | step 2.3 |
| `ANYPOINT_PLATFORM_CLIENT_ID_DEV` / `_TEST` / `_PROD` | step 2.2 |
| `ANYPOINT_PLATFORM_CLIENT_SECRET_DEV` / `_TEST` / `_PROD` | step 2.2 |
| `API_INSTANCE_ID_DEV` / `_TEST` / `_PROD` | step 8.1 |
| `API_BASE_URL_DEV` / `_TEST` | **step 10** |
| `API_BASE_URL_PROD` | after the first prod deploy — see 12.3 |
| `MULE_SECURE_KEY_DEV` / `_TEST` / `_PROD` | you generate — 16 or 32 chars, **one per environment** |
| `TOKEN_URL_DEV` / `_TEST` / `_PROD` | your identity provider's token endpoint |
| `API_CLIENT_ID` / `API_CLIENT_SECRET` | step 8.4, the QA-tier client |
| `UNAPPROVED_CLIENT_ID` / `UNAPPROVED_CLIENT_SECRET` | step 8.4, the client with no contract |

```bash
gh secret set ANYPOINT_ORG_ID --body "your-org-uuid"
gh secret set API_BASE_URL_DEV --body "https://switching-process-api-dev....cloudhub.io"
# ...and so on
```

The per-environment secrets are genuinely distinct. One `MULE_SECURE_KEY`
across all three means a leaked dev key decrypts production secrets — the whole
mechanism, undone.

### 11.2 Environments

**Settings → Environments.** Create `dev`, `test`, `production`.

On `production`, add **required reviewers**. A production deployment here
transmits real requests to a regulated counterparty under the Seller's operator
code. That warrants a human.

### 11.3 The deadline guard

`cd-deploy.yml` refuses production deployments between the 8th and 11th of the
month. Those days straddle the ARERA submission deadline, when the following
month's requests cluster hard. A rolling restart in that window drops
submissions that cannot be retried tomorrow — the window has closed and the
customer waits an extra month.

Override for a genuine incident fix with the repository variable
`OVERRIDE_DEADLINE_GUARD=true`. It should be a decision, not an accident.

---

## 12. Push, and let the pipeline take over

### 12.1 Push

```bash
git add -A
git commit -m "Wire up deployment"
git push origin main
```

**Actions** tab. `CI — build and unit test` runs first, then
`CD — publish, deploy and verify`.

### 12.2 What runs, in order

```
build          → mvn verify (MUnit + coverage gate) → publish to Exchange
deploy-dev     → mvn deploy -DmuleDeploy -Pdev → poll until the app responds
verify-dev     → Karate smoke + full + gateway → Newman
deploy-test    → same artifact, -Ptest
verify-test    → full regression + JMeter peak-day profile
deploy-prod    → deadline guard → manual approval → deploy
verify-prod    → read-only smoke only
```

The artifact is built **once**, and the same binary is promoted through every
environment. Rebuilding per environment is the most common route to running
something in production that no environment ever tested: a fresh dependency
resolution can pull a different patch of a connector, and nothing in the diff
shows it.

Because you deployed by hand in step 10, `deploy-dev` here is an *update* to an
existing application rather than a first creation — which is also the path it
will take on every subsequent run, so you are exercising the real thing.

### 12.3 Production

The first production deploy needs approval, then produces a URL. Add it as
`API_BASE_URL_PROD` so `verify-prod` can smoke it.

### 12.4 Deploying one environment on demand

**Actions → CD — publish, deploy and verify → Run workflow**, pick the
environment. Useful when you want test without touching dev.

---

# Part F — QA automation

## 13. The suites, and what each is for

Six tools, deliberately overlapping, each earning its place.

| Layer | Tool | Sees the gateway? | Location |
|---|---|---|---|
| Flow logic, mocked dependencies | **MUnit** | No | `src/test/munit/` |
| Scenario / regression | **Karate** | Yes | `qa-automation/src/test/java/features/` |
| Schema conformance, JWT attacks, concurrency | **REST Assured** | Yes | `qa-automation/src/test/java/io/.../restassured/` |
| Shareable collection, living documentation | **Postman / Newman** | Yes | `qa-automation/postman/` |
| REST + SOAP end-to-end | **SoapUI / ReadyAPI** | Yes | `qa-automation/soapui/` |
| Peak-day load | **JMeter** | Yes | `qa-automation/jmeter/` |

The dividing line that matters: **MUnit cannot see the gateway.** It runs the
application in isolation and mocks its dependencies. Policies are applied by API
Manager in front of the application, so from MUnit's vantage point they do not
exist. Everything else runs over the wire against a deployed URL.

### 13.1 Running them

```bash
# MUnit — no deployment needed
mvn clean test -Dmule.env=local -Dmule.secure.key=localdevkey12345

cd qa-automation

# Karate: read-only subset (safe against any environment)
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

Karate writes `target/karate-reports/karate-summary.html`. Open it — one of the
better test reports in circulation.

### 13.2 Fixtures that do not expire

Every date is computed at run time relative to today. None is hardcoded.

The pattern is *two months ahead, first of the month*. That date is inside the
submission window on every calendar day, because the deadline for month N+2 is
day 10 of month N+1 — which has not arrived on any day of month N.

Not fussiness. A suite containing `"2025-09-01"` passes for a few weeks and then
fails permanently for calendar reasons. The team learns that red is normal, and
the next real failure goes unnoticed. A fixture that expires is worse than no
fixture.

The one test that *does* depend on today's date —
`closed-submission-window-is-rejected` — is conditionally skipped on or before
the 10th, because on those days the scenario it describes does not exist.
Skipping is honest; rewriting the assertion to pass on every date would test
nothing.

### 13.3 Worth reading for the reasoning

- `duplicate-request-returns-200-not-a-second-sii-submission` — the load-bearing
  assertion is `verify-call ... times="0"`. Asserting only on the response body
  would pass even if a duplicate had been sent to SII and then discarded.
- `SwitchingContractIT.errorResponsesAreSanitised` — SII fault strings can carry
  hostnames and internal identifiers. Those belong in the access-controlled
  audit log, not in a body that reaches a browser.
- `GatewaySecurityIT.forgedSignatureIsRefused` — unexpired, well-formed, correct
  claims, wrong signing key. A policy that reads claims without verifying the
  signature accepts this and passes every other test in the class.

---

## 14. Gateway policy testing

This is the part most portfolios skip, and the part the API QA Engineer role is
really asking about.

### 14.1 Why it needs its own suite

1. **Policies are invisible from inside.** MUnit mocks the world and runs the
   app directly. There is no gateway in the picture.
2. **Failure is silent.** If autodiscovery does not bind, the app runs fine and
   is simply ungoverned. No error, no warning, no log line.
3. **Proving a limit requires breaching it.** Nobody wants to breach a rate
   limit in an environment that matters — so the limit stays unproven.

### 14.2 The autodiscovery health check

`GatewaySecurityIT.anonymousRequestIsRefused` runs first, and its failure
message names the causes:

```
Expected the gateway to refuse an anonymous request but got 200.
If this is 200, API Manager autodiscovery did not bind: check that api.id
matches the API instance in this environment and that
anypoint.platform.client_id/secret were supplied at deploy time.
```

This is the same check you ran manually in step 10.1. A test that tells you
where to look is worth several that only tell you something is wrong.

### 14.3 The JWT cases

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

### 14.4 Proving rate limiting

`GatewaySecurityIT.rateLimitIsEnforced` fires 60 concurrent requests through a
10-thread pool and asserts two things:

- at least one returns **429**
- **none** returns 5xx

The second is the one people forget. A throttled request must be refused
cleanly: a 429 is something clients back off from, a 500 is something they
retry — and retrying deepens an overload rather than relieving it.

This is why the test instance's rate limit is set low in step 8.3. Proving a
production-grade limit from a CI runner measures the runner, not the gateway. A
low limit proves the *mechanism* is wired up. Capacity is a separate question,
answered in step 15.

### 14.5 Writes never touch production

Enforced in three places, because one is not enough:

1. Feature files are tagged `@writes` / `@readonly`; the prod smoke selects
   `@readonly` only.
2. `cd-deploy.yml` calls `api-tests.yml` with `run_writes: false` for prod.
3. `api-tests.yml` hard-fails if `environment == prod && run_writes` — a guard
   against a manual dispatch with the wrong box ticked.

A successful POST against production is a genuine regulated transmission to the
SII under the Seller's operator code. Cancelling it afterwards still counts
against the Seller in ARERA commercial-quality reporting. A stray test run here
is not merely embarrassing.

---

## 15. Performance testing

### 15.1 The profile models the 10th, not the average

`qa-automation/jmeter/switching-deadline-peak.jmx` has two thread groups:

- **TG1 — eligibility reads.** Highest volume, tightest budget (800ms). The
  portal calls this on every form load, so it sits inside a page render.
- **TG2 — submissions.** Lower volume, far more expensive: traverses Salesforce
  then SII over mutual TLS. Budget 3s, against a configured SII timeout of 120s.

That 3s-versus-120s gap is deliberate. The runtime tolerates a slow SII so a
submission near the deadline still completes; the performance gate flags
degradation long before a customer would experience a timeout.

Modelling the average would answer a question nobody has. This platform is
comfortable for three weeks a month and then sees a multiple of its ordinary
traffic in a few hours. "Does the 10th hold?" is the question.

### 15.2 Run it

```bash
cd qa-automation
mvn verify -Pperf \
  -Dapi.base.url=$API_BASE_URL_TEST \
  -Daccess.token=$TOKEN \
  -Dread.threads=50 -Dwrite.threads=10 -Dduration.seconds=300
```

HTML dashboard in `target/jmeter/reports/`.

### 15.3 What the CI numbers are and are not

A hosted GitHub runner is not a load generator. Treat these as a **regression
signal** — "p95 moved 40% against last week" — not a capacity statement. Sizing
for the real peak needs distributed load from an environment resembling the
actual callers, which is a separate exercise from this gate.

Saying so is better than presenting a runner-generated number as a capacity
finding.

---

## 16. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `401` resolving dependencies | Exchange credentials missing or malformed | Step 3. Username is literally `~~~Client~~~`; separator is literally `~?~`. |
| `Could not load keystore` on startup | Bootstrap script not run | `./scripts/bootstrap-local-dev.sh` |
| MUnit fails at startup with a property error | `mule.secure.key` not supplied | Add `-Dmule.secure.key=localdevkey12345` |
| Deploy fails: *target not found* | `ch2.target` mismatch | Step 9 — copy the exact name from the Deploy dialog |
| Deploy succeeds, app crashes on start | `api.id` invalid, or platform client ID/secret missing | Check `API_INSTANCE_ID_*` and `ANYPOINT_PLATFORM_CLIENT_*` |
| **Anonymous request returns 200** | Autodiscovery did not bind | The app is ungoverned. Check `api.id` matches the instance *in this environment*, and that platform client ID/secret were passed at deploy. |
| **Anonymous request returns an empty `503`** | Autodiscovery bound to a nonexistent instance | The gatekeeper policy is holding all traffic waiting for a policy set that never arrives. Usually a placeholder or mistyped `api.id`. Note this is the *opposite* of the failure mode in 8.2 — it fails closed, not open. |
| **Every request returns a bare `502`**, app healthy at `1/1` replicas | Ingress cannot reach the listener | `lastMileSecurity` must be nested under `deploymentSettings/http/inbound`. At the top level it is accepted and silently ignored. See 10.0 point 5. |
| `ForwardSslSession is not supported for the given deployment target` | Shared space | It needs a private space. Remove it; keep `lastMileSecurity`. |
| `Couldn't find environmentName named [Sandbox]` | Environment names differ | Check **Access Management → Environments**. An org may have `dev`/`test`/`prod` rather than `Sandbox`/`Production`. Fix `deploy.env` in each `pom.xml` profile. |
| `403` on `.../targets/<target>/environments/<env>/domains` | Connected App missing **Cloudhub Network Administrator** | Step 2.3. No other Runtime Manager scope grants it, including Cloudhub Organization Admin, and the message names only a path. |
| `404 ... There is no asset matching given parameters` on deploy | Artifact never published to Exchange | CloudHub 2.0 deploys *from* Exchange. Publish first with `mvn deploy` **without** `-DmuleDeploy`. See 10.0 point 3. |
| `The groupId '<x>' is invalid. It must be your organization UUID` | `groupId` is not the org UUID | Exchange requires it. See 10.0 point 2. |
| `An asset already exists with this version and published lifecycle state` | Republishing an existing Exchange version | Exchange versions are immutable. Bump `<version>` in `pom.xml`. |
| `CrashLoopBackOff — Couldn't find resource: properties/<env>.secure.yaml` | Environment files were never generated | `bootstrap-local-dev.sh` only creates the `local` set. See 10.0 point 1. Applies to the `<env>-keystore.jks` and `<env>-truststore.jks` too. |
| `API <id>: Not Ready. API not found in the API Platform` | `api.id` wrong, or not forwarded to the app | Compare the id in the message against the instance id in API Manager — a dropped digit produces exactly this. Confirm `cloudhub2Deployment/properties` forwards `api.id`. See 10.0 point 4. |
| `Cannot create embedded container` / `401` on `com.mulesoft.licm:licm` | No Mule EE runtime entitlement | MUnit needs a licensed EE runtime from MuleSoft's private Nexus, which Exchange credentials do not cover. Run the suites in Anypoint Studio; pass `-DskipMunitTests` when deploying. |
| `403` on `deploy-prod` only | Connected App missing Production scope | Step 2.3 — Runtime Manager scopes need every environment ticked |
| CI verify jobs fail on first run | `API_BASE_URL_*` not set | You skipped step 10. Deploy by hand, capture the URL, then set the secret. |
| Rate-limit test finds no 429 | Policy absent, or threshold above what CI can reach | Step 8.3 — add SLA rate limiting and set the QA tier low |
| Karate: connection refused right after deploy | CloudHub reports complete before the replica serves | The workflow's wait loop handles this; locally, allow 60–90s |
| Newman: `client_secret` undefined | Env file ships empty on purpose | Pass `--env-var "client_secret=$SECRET"` |
| Coverage gate fails on a fresh clone | Threshold above current coverage | Lower it in `pom.xml`, ratchet up as tests are added |

---

## 17. What this maps to on a job description

For the API QA Engineer (MuleSoft) posting:

| Requirement | Where it lives |
|---|---|
| Test strategies for custom APIs and backend APIs behind a gateway | Steps 13–15; the layer split in 13 |
| Functional, integration, regression, end-to-end across distributed systems | MUnit, Karate features, SoapUI end-to-end project |
| Validate auth/authz — OAuth2, JWT, API keys | `GatewaySecurityIT`, `TestTokens`, `features/gateway/` |
| Request/response transformation, error handling, edge cases | Schema conformance in `SwitchingContractIT`; sanitisation and 422-vs-400 assertions |
| Performance, reliability, scalability | `switching-deadline-peak.jmx` with SLO assertions as build gates |
| Automation frameworks for API testing | `qa-automation/` — standalone Maven project, environment-parameterised |
| Postman, REST Assured, Karate, SoapUI, ReadyAPI, JMeter | All six, each with a stated reason rather than for the sake of the list |
| Integrate tests into CI/CD; reusable test data and mock services | `api-tests.yml` as a reusable workflow; computed fixtures |
| Validate gateway config — routing, rate limiting, security, transformation | Step 14 in full; policy setup in step 8.3 |
| End-to-end across gateway, middleware, backend | SoapUI project spans the REST experience layer and the SOAP/XML SII boundary |
| Troubleshoot integration issues across systems | Step 16; failure messages written to name the likely cause |
| CI/CD tooling — Jenkins, Azure DevOps, GitHub Actions, GitLab CI | GitHub Actions here; the build-once-promote-the-binary model transfers unchanged |
| Java, Python, JavaScript | Java (REST Assured, JWT minting), JavaScript (Karate config, Postman), Groovy (JMeter, SoapUI) |

The thing worth being able to talk about in an interview is not the tool list —
it is 14.2. Most candidates can describe a rate-limiting policy. Fewer can
explain that autodiscovery failure is silent, that an ungoverned application
looks identical to a governed one from outside, and that the first assertion in
the suite exists to catch exactly that.

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
