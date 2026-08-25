@ignore
Feature: Submit one inadmissible switching request and assert it is refused

  # Called data-driven from submit-switching-request.feature: passing an array
  # to karate.call runs this feature once per element, with each element's
  # keys available as variables.
  #
  # This exists because a dynamic Scenario Outline could not be made to work.
  # Karate resolves the Examples expression when it expands the outline, and
  # neither a Background `def` nor a karate-config.js value is in scope at
  # that point — both fail with ReferenceError. A data-driven call is
  # evaluated at run time, where the variables genuinely exist.

  Scenario: submit
    Given url baseUrl
    And path 'switching-requests'
    And header Authorization = 'Bearer ' + accessToken
    And header x-channel = 'B2C_PORTAL'
    And request { pdr: '#(pdr)', customerType: '#(customerType)', fiscalCode: '#(fiscalCode)', effectiveDate: '#(effectiveDate)' }
    When method post
    # 422 rather than 400: the request is well-formed, the regulation refuses
    # it. The portals branch on this — a 400 is retried after correction, a 422
    # is surfaced to the customer as a business outcome.
    Then status 422
    And match response.error.code == '#string'
    And match response.error.correlationId == '#string'
    # The reason must be specific enough for the portal to render it. "Request
    # failed" produces a contact-centre call; "the window for 1 August closed
    # on 10 July" does not.
    And match response.error.message != 'An unexpected error occurred.'
