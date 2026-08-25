@ignore
Feature: One eligibility call, used to build load in rate-limit scenarios

  Scenario: call
    Given url baseUrl
    And path 'supply-points', pdr, 'eligibility'
    And header Authorization = 'Bearer ' + token
    When method get
    # No status assertion: the caller inspects the status itself. A 429 is the
    # expected outcome for most of a burst and must not fail the helper.
    #
    # Named `status` and `headers`, not `responseStatus` and `responseHeaders`.
    # Karate returns the called feature's variables to the caller, so the
    # values have to be assigned to something — but assigning a built-in to
    # itself (`* def responseStatus = responseStatus`) shadows it rather than
    # copying it, and the caller receives null. A burst then collects an array
    # of nulls, finds no 429 in it, and reports that rate limiting is not
    # working while the gateway is in fact throttling correctly.
    * def status = responseStatus
    * def headers = responseHeaders
