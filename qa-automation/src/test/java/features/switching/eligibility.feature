@switching @functional @smoke @readonly
Feature: Switching eligibility pre-flight

  # ===========================================================================
  # GET /supply-points/{pdr}/eligibility
  # ===========================================================================
  # Read-only, so it is safe to run against production as part of the smoke
  # suite — tagged @readonly and @smoke for that reason.
  #
  # The invariant under test is a cross-endpoint one: every date this endpoint
  # advertises as available must be a date POST /switching-requests would
  # accept. The two derive from the same regulation but not, in the code, from
  # the same expression — so drift between them is possible and would show up
  # to the customer as "the portal offered me 1 September and then refused it".
  # ===========================================================================

  Background:
    * url baseUrl
    * configure headers = accessToken ? { Authorization: 'Bearer ' + accessToken } : {}
    * def timeLib = Java.type('java.time.LocalDate')

  Scenario: The calendar returned is well-formed and cites its regulatory basis
    Given path 'supply-points', validPdr, 'eligibility'
    When method get
    Then status 200
    And match response ==
      """
      {
        pdr: '#(validPdr)',
        earliestAvailableEffectiveDate: '#string',
        currentWindow: {
          deadlineDay: '#number',
          openForNextMonth: '#boolean',
          note: '#string'
        },
        availableDates: '#[_ > 0]',
        regulatoryBasis: '#string'
      }
      """
    # Delibera 77/2018/R/com fixes the deadline at day 10. If this ever returns
    # something else, either the regulation changed or the rule module was
    # edited without its documentation — both need a human to look.
    And match response.currentWindow.deadlineDay == submissionDeadlineDay

  Scenario: Every advertised date is the first day of a month
    Given path 'supply-points', validPdr, 'eligibility'
    When method get
    Then status 200
    * def days = $response.availableDates[*].effectiveDate
    * def allFirstOfMonth = function(dates){ for (var i = 0; i < dates.length; i++) { if (!dates[i].endsWith('-01')) return false } return true }
    And match allFirstOfMonth(days) == true

  Scenario: Every advertised date has a deadline that precedes it
    Given path 'supply-points', validPdr, 'eligibility'
    When method get
    Then status 200
    * def check =
      """
      function(rows) {
        for (var i = 0; i < rows.length; i++) {
          if (rows[i].submissionDeadline >= rows[i].effectiveDate) return false;
        }
        return true;
      }
      """
    And match check(response.availableDates) == true

  Scenario: The window flag agrees with today's date
    Given path 'supply-points', validPdr, 'eligibility'
    When method get
    Then status 200
    * def todayDay = timeLib.now().getDayOfMonth()
    * def expectedOpen = todayDay <= submissionDeadlineDay
    # This is the assertion that catches a timezone misconfiguration on the
    # replica. A runtime in the wrong zone shifts the boundary by a day, which
    # is invisible for 29 days a month and catastrophic on the 10th.
    And match response.currentWindow.openForNextMonth == expectedOpen

  Scenario: A malformed PDR is rejected at the contract boundary
    Given path 'supply-points', 'NOT-A-PDR', 'eligibility'
    When method get
    Then status 400
