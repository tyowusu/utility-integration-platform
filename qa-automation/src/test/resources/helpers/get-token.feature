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
    # audience identifies which API the token is for. Auth0 requires it on a
    # client-credentials grant against a custom API: omit it and you get either
    # an error or a token minted for the provider's own management API, whose
    # aud claim the gateway's JWT policy then rejects — a 401 that looks like
    # bad credentials rather than a missing parameter.
    #
    # Providers differ. Okta and Azure AD infer the audience from scope, so a
    # tenant on those may leave api.audience empty.
    And form field audience = audience
    When method post
    Then status 200
    * def accessToken = response.access_token
