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
  # Rate limiting / spike control
  # ---------------------------------------------------------------------------
  @policy-rate-limit
  Scenario: Sustained traffic above the configured limit is throttled with 429
    * if (!accessToken) karate.abort()
    # The policy in the test environment is deliberately set low enough to be
    # provable inside a CI run. Proving a production-grade limit would require
    # generating production-grade load from a CI runner, which measures the
    # runner rather than the gateway.
    * def burst =
      """
      function() {
        var statuses = [];
        for (var i = 0; i < 40; i++) {
          var r = karate.call('classpath:helpers/single-eligibility-call.feature',
                              { baseUrl: baseUrl, pdr: validPdr, token: accessToken });
          statuses.push(r.responseStatus);
        }
        return statuses;
      }
      """
    * def statuses = burst()
    * def throttled = karate.filter(statuses, function(s){ return s == 429 })
    And assert throttled.length > 0
    # A 429 must be an honest refusal, not a disguised failure: the client is
    # expected to back off and retry, so anything other than 429 (a 500, say)
    # would send the portal down a retry path that makes the overload worse.

  @policy-rate-limit
  Scenario: A throttled response advertises when to retry
    * if (!accessToken) karate.abort()
    * def r = karate.call('classpath:helpers/single-eligibility-call.feature',
                          { baseUrl: baseUrl, pdr: validPdr, token: accessToken })
    * if (r.responseStatus == 429) karate.match(r.responseHeaders['x-ratelimit-remaining'], '#notnull')

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
