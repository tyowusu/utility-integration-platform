@switching @functional @writes
Feature: Submit a switching request (cambio venditore)

  # ===========================================================================
  # FUNCTIONAL SUITE — POST /switching-requests
  # ===========================================================================
  # Acceptance criteria trace directly to Delibera ARERA 77/2018/R/com:
  #   - the effective date must be the first day of a month
  #   - the request must reach SII by the 10th of the preceding month
  #
  # Tagged @writes. Excluded from the production smoke run, because a
  # successful POST here is a real regulated transmission to the SII under the
  # Seller's operator code, not a test.
  # ===========================================================================

  Background:
    * url baseUrl
    * def timeLib = Java.type('java.time.LocalDate')
    # Two months ahead is inside the submission window on every day of the
    # month, so the fixture never expires. One month ahead is only valid on or
    # before the 10th, which is exactly what the boundary scenarios exercise.
    * def firstOfMonthIn =
      """
      function(months) {
        var d = timeLib.now().plusMonths(months).withDayOfMonth(1);
        return d.toString();
      }
      """
    * def validEffectiveDate = firstOfMonthIn(2)
    # Built with withDayOfMonth rather than string replacement. A naive
    # '2026-01-01'.replace('-01','-15') hits the *month* segment first and
    # yields '2026-15-01' — a bug that lies dormant for eleven months a year.
    * def dayOfMonthIn =
      """
      function(months, day) {
        return timeLib.now().plusMonths(months).withDayOfMonth(day).toString();
      }
      """
    * def midMonthDate = dayOfMonthIn(2, 15)
    * def pastDate = firstOfMonthIn(-2)
    * def uniquePdr = function(){ return '9' + java.lang.System.currentTimeMillis().toString().slice(-13) }
    * configure headers = accessToken ? { Authorization: 'Bearer ' + accessToken, 'x-channel': 'B2C_PORTAL' } : { 'x-channel': 'B2C_PORTAL' }

    # inadmissibleCases lives in karate-config.js, not here. Karate resolves a
    # dynamic Examples expression when it expands the outline, before this
    # Background has run — so defining it here yields
    # ReferenceError: "inadmissibleCases" is not defined and the outline never
    # executes a single case.

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------
  Scenario: A valid residential request inside the window is accepted with 202
    Given path 'switching-requests'
    And request
      """
      {
        "pdr": "#(uniquePdr())",
        "customerType": "RESIDENTIAL",
        "fiscalCode": "#(validCodiceFiscale)",
        "firstName": "Mario",
        "lastName": "Rossi",
        "effectiveDate": "#(validEffectiveDate)"
      }
      """
    When method post
    Then status 202
    And match response ==
      """
      {
        requestId: '#string',
        status: 'SUBMITTED',
        pdr: '#string',
        effectiveDate: '#(validEffectiveDate)',
        outcomeExpectedBy: '#string',
        message: '#string'
      }
      """
    # The 202 is the contract's whole point: the distributor's admissibility
    # decision has NOT been made yet. A 200 here would tell the portal the
    # switch succeeded, which is the single most common defect in SII
    # integrations.
    And match responseStatus == 202

  Scenario: A valid business request is accepted with a partita IVA
    Given path 'switching-requests'
    And header x-channel = 'B2B_PORTAL'
    And header x-operator-id = 'AGENT-0042'
    And request
      """
      {
        "pdr": "#(uniquePdr())",
        "customerType": "BUSINESS",
        "fiscalCode": "#(validPartitaIva)",
        "businessName": "Rossi Energia SRL",
        "effectiveDate": "#(validEffectiveDate)"
      }
      """
    When method post
    Then status 202
    And match response.status == 'SUBMITTED'

  # ---------------------------------------------------------------------------
  # Regulatory rejections — 422, not 400
  # ---------------------------------------------------------------------------
  # A dynamic Scenario Outline rather than a static Examples table. The cases
  # depend on today's date, and a static table would either hardcode dates that
  # expire or omit the date-sensitive cases entirely — which are the cases most
  # worth having.
  Scenario: Requests the regulation refuses are rejected with 422
    * if (!accessToken) karate.abort()
    # Data-driven: passing the array to karate.call runs the helper once per
    # case, so a new inadmissibility rule is a new entry in karate-config.js
    # rather than a new scenario here.
    #
    # Not a dynamic Scenario Outline. Karate resolves the Examples expression
    # when it expands the outline, and neither a Background def nor a
    # karate-config.js value is in scope then — both give
    # ReferenceError: "inadmissibleCases" is not defined, and the outline runs
    # no cases at all while looking like three passing scenarios.
    * def results = karate.call('classpath:helpers/submit-inadmissible.feature', inadmissibleCases)
    * match results == '#[4]'

  # ---------------------------------------------------------------------------
  # Contract violations — 400, caught by APIkit before any business logic
  # ---------------------------------------------------------------------------
  Scenario: A PDR with the wrong number of digits is a contract violation
    Given path 'switching-requests'
    And request
      """
      {
        "pdr": "1234567890123",
        "customerType": "RESIDENTIAL",
        "fiscalCode": "#(validCodiceFiscale)",
        "effectiveDate": "#(validEffectiveDate)"
      }
      """
    When method post
    # The RAML constrains pdr to ^[0-9]{14}$, so APIkit rejects this at the
    # boundary. Asserting on the union of 400/422 would hide a regression in
    # which schema enforcement silently stops running.
    Then status 400
    And match response.error.correlationId == '#string'

  Scenario: An unrecognised channel header is rejected
    Given path 'switching-requests'
    And header x-channel = 'CARRIER_PIGEON'
    And request
      """
      {
        "pdr": "#(uniquePdr())",
        "customerType": "RESIDENTIAL",
        "fiscalCode": "#(validCodiceFiscale)",
        "effectiveDate": "#(validEffectiveDate)"
      }
      """
    When method post
    Then status 400

  Scenario: A missing required field is rejected
    Given path 'switching-requests'
    And request
      """
      {
        "pdr": "#(uniquePdr())",
        "customerType": "RESIDENTIAL",
        "fiscalCode": "#(validCodiceFiscale)"
      }
      """
    When method post
    Then status 400

  # ---------------------------------------------------------------------------
  # Idempotency
  # ---------------------------------------------------------------------------
  Scenario: A repeated submission returns the original request, not a new one
    * def pdr = uniquePdr()
    * def body =
      """
      {
        "pdr": "#(pdr)",
        "customerType": "RESIDENTIAL",
        "fiscalCode": "#(validCodiceFiscale)",
        "effectiveDate": "#(validEffectiveDate)"
      }
      """

    Given path 'switching-requests'
    And request body
    When method post
    Then status 202
    * def firstRequestId = response.requestId

    # Same supply point, same effective date. A customer double-clicking, or a
    # portal retrying on timeout, must not produce two SII transactions — the
    # second is rejected by SII and counts against the Seller in ARERA
    # commercial-quality reporting.
    Given path 'switching-requests'
    And request body
    When method post
    Then status 200
    And match response.status == 'ALREADY_SUBMITTED'
    And match response.requestId == firstRequestId
