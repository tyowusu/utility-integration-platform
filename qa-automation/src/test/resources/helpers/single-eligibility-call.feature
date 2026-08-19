@ignore
Feature: One eligibility call, used to build load in rate-limit scenarios

  Scenario: call
    Given url baseUrl
    And path 'supply-points', pdr, 'eligibility'
    And header Authorization = 'Bearer ' + token
    When method get
    # No status assertion: the caller inspects responseStatus. A 429 is the
    # expected outcome for most of a burst and must not fail the helper.
    * def responseStatus = responseStatus
    * def responseHeaders = responseHeaders
