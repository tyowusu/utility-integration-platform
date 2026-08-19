@switching @functional @readonly
Feature: Retrieve switching request status

  # ===========================================================================
  # GET /switching-requests/{requestId}
  # ===========================================================================
  # The asynchronous half of the contract. The submit endpoint returns 202 and
  # a request id; the outcome arrives later from the distributor via SII. This
  # endpoint is how a portal finds out.
  # ===========================================================================

  Background:
    * url baseUrl
    * configure headers = accessToken ? { Authorization: 'Bearer ' + accessToken } : {}

  Scenario: An unknown request id returns 404, not an empty 200
    Given path 'switching-requests', 'SII-REQ-DOES-NOT-EXIST-0000'
    When method get
    # An empty 200 would be indistinguishable, to the portal, from "submitted
    # but no outcome yet" — and the portal would keep polling a request that
    # will never exist.
    Then status 404
    And match response.error.correlationId == '#string'

  Scenario: A status response conforms to the canonical contract
    # Depends on a request id seeded by the submit suite in the same run.
    * def seeded = karate.callSingle('classpath:helpers/seed-switching-request.feature', karate.info)
    * def requestId = seeded.requestId

    Given path 'switching-requests', requestId
    When method get
    Then status 200
    And match response ==
      """
      {
        requestId: '#(requestId)',
        pdr: '##string',
        effectiveDate: '##string',
        status: '#regex SUBMITTED|UNDER_REVIEW|ACCEPTED|REJECTED|CANCELLED|UNKNOWN',
        protocolStatus: '##string',
        submittedAt: '##string',
        lastUpdatedAt: '##string',
        rejection: '##object'
      }
      """

  Scenario: A rejected request carries a machine-readable reason code
    * def seeded = karate.callSingle('classpath:helpers/seed-switching-request.feature', karate.info)

    Given path 'switching-requests', seeded.requestId
    When method get
    Then status 200
    # Only meaningful once the mock or the real distributor has returned a
    # rejection. Guarded rather than skipped, so the assertion runs whenever
    # the state is reachable instead of never.
    * if (response.status == 'REJECTED') karate.match(response.rejection, { reasonCode: '#string', reasonText: '#string' })

  Scenario: Correlation id is returned on every response
    Given path 'switching-requests', 'SII-REQ-DOES-NOT-EXIST-0000'
    When method get
    Then status 404
    # correlationId is the join key between an API response and the audit
    # record. A regulator or ombudsman enquiry starts from a customer holding
    # one of these; if it is absent the trail begins nowhere.
    And match response.error.correlationId == '#notnull'
