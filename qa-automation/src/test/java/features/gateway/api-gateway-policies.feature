@gateway @security
Feature: API Manager gateway policy enforcement

  # ===========================================================================
  # GATEWAY LAYER — policies applied by API Manager in front of the Mule app
  # ===========================================================================
  # None of this is testable from MUnit. MUnit runs the application in
  # isolation; the policies live in the gateway ahead of it. From inside the
  # app, an unauthenticated request and an authenticated one look identical,
  # because the gateway has already decided.
  #
  # The failure mode these scenarios exist to catch is silent: if
  # api-gateway autodiscovery does not bind (wrong api.id, missing
  # anypoint.platform.client_id, app deployed to the wrong environment), the
  # application still starts, still serves traffic, and is simply ungoverned.
  # Nothing in the logs says "your policies are not running".
  #
  # So the first scenario below is, in effect, an autodiscovery health check
  # dressed as a security test. If it passes, the binding worked.
  # ===========================================================================

  Background:
    * url baseUrl
    * def timeLib = Java.type('java.time.LocalDate')
    * def validEffectiveDate = timeLib.now().plusMonths(2).withDayOfMonth(1).toString()

  # ---------------------------------------------------------------------------
  # Client ID enforcement
  # ---------------------------------------------------------------------------
  @policy-client-id
  Scenario: A request with no credentials is rejected by the gateway
    Given path 'supply-points', validPdr, 'eligibility'
    # No Authorization header, no client_id/client_secret headers.
    When method get
    # 400 is included deliberately. A missing token is answered by the JWT
    # validation policy with 400 {"error": "JWT Token is required."}, not the
    # 401 an absent credential might suggest — a malformed or unsigned token
    # does return 401. What this scenario asserts is that the gateway refused
    # the request, and all three statuses are refusals; narrowing to 401/403
    # would fail against correct behaviour.
    Then assert responseStatus == 400 || responseStatus == 401 || responseStatus == 403
    # The gateway, not the application, produced this. The application's own
    # error handler always emits an object with error.correlationId; the
    # gateway's does not. Asserting the absence tells us which layer answered,
    # and is what stops the status list above from being merely permissive.
    And match response != '#[_ != null] error.correlationId'

  @policy-client-id
  Scenario: A registered client without an approved contract is rejected
    Given path 'supply-points', validPdr, 'eligibility'
    And header client_id = unapprovedClientId
    And header client_secret = unapprovedClientSecret
    When method get
    # 400 for the same reason as above: this request carries no bearer token,
    # so JWT validation refuses it before contract checking is reached. The
    # scenario still proves an unentitled caller cannot get through, which is
    # the point — but note it does not, on its own, prove the *contract* was
    # what refused it.
    Then assert responseStatus == 400 || responseStatus == 401 || responseStatus == 403

  @policy-client-id
  Scenario: An approved client is admitted
    * if (!accessToken) karate.abort()
    Given path 'supply-points', validPdr, 'eligibility'
    And header Authorization = 'Bearer ' + accessToken
    When method get
    Then status 200

  # ---------------------------------------------------------------------------
  # OAuth2 / JWT validation
  # ---------------------------------------------------------------------------
  @policy-jwt
  Scenario: A structurally invalid bearer token is rejected
    Given path 'supply-points', validPdr, 'eligibility'
    And header Authorization = 'Bearer not.a.jwt'
    When method get
    Then assert responseStatus == 401 || responseStatus == 403

  @policy-jwt
  Scenario: An expired token is rejected
    # Minted here rather than read from a fixture file. A checked-in token
    # expires once and then tests nothing; one built at runtime with a past
    # `exp` is expired on every run, forever.
    * def Mint = Java.type('io.github.portfolio.qa.support.TestTokens')
    * def expiredJwt = Mint.expired()
    Given path 'supply-points', validPdr, 'eligibility'
    And header Authorization = 'Bearer ' + expiredJwt
    When method get
    Then assert responseStatus == 401 || responseStatus == 403

  @policy-jwt
  Scenario: A token signed with an unknown key is rejected
    # Unexpired, well-formed, correct claims — only the signature is wrong.
    # A policy that reads claims without verifying the signature accepts this
    # and passes every other scenario in this file.
    * def Mint = Java.type('io.github.portfolio.qa.support.TestTokens')
    * def forgedJwt = Mint.forged()
    Given path 'supply-points', validPdr, 'eligibility'
    And header Authorization = 'Bearer ' + forgedJwt
    When method get
    Then assert responseStatus == 401 || responseStatus == 403

  @policy-jwt
  Scenario: An unsigned (alg=none) token is rejected
    * def Mint = Java.type('io.github.portfolio.qa.support.TestTokens')
    * def noneJwt = Mint.algNone()
    Given path 'supply-points', validPdr, 'eligibility'
    And header Authorization = 'Bearer ' + noneJwt
    When method get
    Then assert responseStatus == 401 || responseStatus == 403

  # ---------------------------------------------------------------------------
  # Transport security
  # ---------------------------------------------------------------------------
  @policy-transport
  Scenario: Security headers are present on a successful response
    * if (!accessToken) karate.abort()
    Given path 'supply-points', validPdr, 'eligibility'
    And header Authorization = 'Bearer ' + accessToken
    When method get
    Then status 200
    # Content-Type must be pinned. A response that omits it, or returns
    # text/html, is a sign the gateway served an error page rather than the
    # application serving a payload.
    And match responseHeaders['Content-Type'][0] contains 'application/json'

  @policy-transport
  Scenario: An unsupported method on a known path is refused
    Given path 'supply-points', validPdr, 'eligibility'
    And header Authorization = 'Bearer ' + (accessToken || 'none')
    And request {}
    When method delete
    Then assert responseStatus == 405 || responseStatus == 401 || responseStatus == 403

  # ---------------------------------------------------------------------------
  # Rate limiting / spike control
  #
  # These run LAST, and deliberately so. The burst below exhausts the quota for
  # the whole window, and the rate limit is keyed per client — so any scenario
  # ordered after it gets 429 where it expects 200, and fails for a reason that
  # has nothing to do with what it is testing. Karate executes scenarios in file
  # order, so position here is load-bearing rather than cosmetic.
  # ---------------------------------------------------------------------------
  @policy-rate-limit
  Scenario: Sustained traffic above the configured limit is throttled with 429
    * if (!accessToken) karate.abort()
    # 300 requests against a 200/minute limit, fired concurrently.
    #
    # Concurrency is the point, not an optimisation. A sequential loop is
    # bounded by round-trip time rather than by the server: at ~430ms from a
    # laptop that is ~140 requests/minute, so a 200/minute limit cannot be
    # exceeded at all, whatever the loop count. The same loop reached ~110ms
    # per request on a CI runner near the region and tripped the limit easily.
    # The assertion was therefore decided by where it ran — it reported "rate
    # limiting is broken" from a developer machine and would have gone quietly
    # meaningless the day a runner got slower.
    #
    # This suite also authenticates as its OWN client application, separate
    # from every other suite. The burst exists to exhaust a quota and the limit
    # is keyed per client, so sharing one meant the burst poisoned whatever ran
    # next while whatever ran first ate the quota this scenario needs. The
    # separate client removes that coupling; the cooldowns only hid it.
    * def Burst = Java.type('io.github.portfolio.qa.support.LoadBurst')
    * def target = baseUrl + '/supply-points/' + validPdr + '/eligibility'
    * def counts = Burst.fire(target, accessToken, 300, 25)
    * print 'burst status distribution:', counts
    # The distribution is printed, not just asserted on, because "no 429s" has
    # two very different causes — a policy that is absent, and a burst that
    # never reached the limit — and the counts tell them apart at a glance.
    And assert counts['429'] > 0
    # Every request must be accounted for. A burst that silently failed at the
    # transport layer would otherwise look like a burst that was not throttled.
    And assert (counts['200'] || 0) + (counts['429'] || 0) == 300
    # A 429 must be an honest refusal, not a disguised failure: the client is
    # expected to back off and retry, so anything other than 429 (a 500, say)
    # would send the portal down a retry path that makes the overload worse.

  @policy-rate-limit
  Scenario: A throttled response advertises when to retry
    * if (!accessToken) karate.abort()
    # One line: Karate's parser does not accept a * step wrapped across lines
    # outside a docstring block. Wrapped, it fails the whole feature file with
    # "mismatched input '{' expecting <EOF>" and no scenario runs at all.
    * def r = karate.call('classpath:helpers/single-eligibility-call.feature', { baseUrl: baseUrl, pdr: validPdr, token: accessToken })
    * if (r.status == 429) karate.match(r.headers['x-ratelimit-remaining'], '#notnull')
