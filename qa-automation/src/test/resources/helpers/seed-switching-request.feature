@ignore
Feature: Seed a switching request and return its id

  # Called via karate.callSingle so it executes at most once per suite run,
  # regardless of how many scenarios depend on it. Seeding per scenario would
  # transmit a fresh regulated request each time and would make the status
  # suite's own traffic the largest consumer of SII quota.

  Background:
    * url baseUrl
    * def timeLib = Java.type('java.time.LocalDate')
    * def validEffectiveDate = timeLib.now().plusMonths(2).withDayOfMonth(1).toString()
    * def pdr = '9' + java.lang.System.currentTimeMillis().toString().slice(-13)
    * configure headers = accessToken ? { Authorization: 'Bearer ' + accessToken, 'x-channel': 'B2C_PORTAL' } : { 'x-channel': 'B2C_PORTAL' }

  Scenario: seed
    Given path 'switching-requests'
    And request
      """
      {
        "pdr": "#(pdr)",
        "customerType": "RESIDENTIAL",
        "fiscalCode": "RSSMRA80A01H501U",
        "firstName": "Seed",
        "lastName": "Fixture",
        "effectiveDate": "#(validEffectiveDate)"
      }
      """
    When method post
    Then assert responseStatus == 202 || responseStatus == 200
    * def requestId = response.requestId
