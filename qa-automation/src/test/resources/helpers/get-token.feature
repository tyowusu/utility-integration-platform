@ignore
Feature: Obtain an OAuth2 access token by client credentials

  # Called once from karate-config.js. Tagged @ignore so it is never picked up
  # as a suite in its own right.

  Background:
    * url tokenUrl

  Scenario: fetch token
    Given form field grant_type = 'client_credentials'
    And form field client_id = clientId
    And form field client_secret = clientSecret
    When method post
    Then status 200
    * def accessToken = response.access_token
