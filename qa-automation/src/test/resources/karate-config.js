/*
 * =============================================================================
 * KARATE ENVIRONMENT CONFIGURATION
 * =============================================================================
 * Resolves the target environment and the credentials used to reach it.
 *
 * Nothing secret is stored here. Client credentials arrive as system
 * properties, which in CI are populated from GitHub Actions secrets and in
 * local use from the developer's shell. A committed credential in a QA suite
 * is still a committed credential.
 * =============================================================================
 */
function fn() {

    var env = karate.env || java.lang.System.getProperty('karate.env') || 'dev';
    karate.log('karate.env =', env);

    var config = {
        env: env,

        // ---------------------------------------------------------------
        // Regulatory constants, mirrored from the DataWeave rule module.
        // Kept here so a feature file reads as a statement about the
        // regulation rather than a magic number.
        // ---------------------------------------------------------------
        submissionDeadlineDay: 10,
        validPdr: '12345678901234',
        validCodiceFiscale: 'RSSMRA80A01H501U',
        validPartitaIva: '12345678901',

        /*
         * Inadmissibility cases for the dynamic Scenario Outline in
         * submit-switching-request.feature.
         *
         * Defined here rather than in that feature's Background because
         * Karate resolves a dynamic Examples expression when it expands the
         * outline — before the Background has run for that scenario — so a
         * variable defined there is not yet in scope and the outline fails
         * with ReferenceError: "inadmissibleCases" is not defined.
         *
         * Dates are computed at run time relative to today, never hardcoded:
         * a fixture containing a literal date passes for a few weeks and then
         * fails permanently for calendar reasons, which teaches the team that
         * red is normal.
         */
        inadmissibleCases: (function () {
            var LocalDate = Java.type('java.time.LocalDate');
            var firstOfMonthIn = function (months) {
                return LocalDate.now().plusMonths(months).withDayOfMonth(1).toString();
            };
            var CF = 'RSSMRA80A01H501U';
            var PIVA = '12345678901';
            return [
                { description: 'Mid-month effective date',
                  pdr: '12345678901234', customerType: 'RESIDENTIAL',
                  fiscalCode: CF,
                  effectiveDate: LocalDate.now().plusMonths(2).withDayOfMonth(15).toString() },

                { description: 'Business customer presenting a codice fiscale',
                  pdr: '12345678901234', customerType: 'BUSINESS',
                  fiscalCode: CF, effectiveDate: firstOfMonthIn(2) },

                { description: 'Residential customer presenting a partita IVA',
                  pdr: '12345678901234', customerType: 'RESIDENTIAL',
                  fiscalCode: PIVA, effectiveDate: firstOfMonthIn(2) },

                { description: 'Effective date in the past',
                  pdr: '12345678901234', customerType: 'RESIDENTIAL',
                  fiscalCode: CF, effectiveDate: firstOfMonthIn(-2) }
            ];
        })(),

        // Populated below.
        baseUrl: null,
        clientId: java.lang.System.getProperty('client.id') || '',
        clientSecret: java.lang.System.getProperty('client.secret') || '',
        tokenUrl: java.lang.System.getProperty('token.url') || '',

        /*
         * Which API the token is issued for. Required by Auth0 on a
         * client-credentials grant; inferred from scope by Okta and Azure AD.
         *
         * Per-environment by design. Sharing one audience across dev, test and
         * prod means a token minted for dev is cryptographically valid in
         * prod, and only API Manager contracts stop it being accepted — the
         * isolation rests entirely on the contract layer. Registering a
         * separate audience per environment moves that check into the token
         * itself, where a mismatch is refused before contracts are consulted.
         */
        audience: java.lang.System.getProperty('api.audience') || 'switching-experience-api',

        // A client registered to the API instance but WITHOUT an approved
        // contract. Used to prove that client-id enforcement rejects it.
        unapprovedClientId: java.lang.System.getProperty('unapproved.client.id') || 'not-a-registered-client',
        unapprovedClientSecret: java.lang.System.getProperty('unapproved.client.secret') || 'not-a-real-secret'
    };

    if (env === 'local') {
        config.baseUrl = 'https://localhost:8082/api';
    } else if (env === 'dev') {
        config.baseUrl = java.lang.System.getProperty('api.base.url') + '/api';
    } else if (env === 'test') {
        config.baseUrl = java.lang.System.getProperty('api.base.url') + '/api';
    } else if (env === 'prod') {
        /*
         * Production runs only the read-only smoke subset. Submitting a
         * switching request against production would transmit a real request
         * to SII under the Seller's operator code — a regulated act, not a
         * test. Feature files tagged @writes are excluded in the prod run.
         */
        config.baseUrl = java.lang.System.getProperty('api.base.url') + '/api';
    }

    // Self-signed certificates in the non-production environments.
    if (env === 'local' || env === 'dev') {
        karate.configure('ssl', true);
    }

    karate.configure('connectTimeout', 10000);
    karate.configure('readTimeout', 30000);

    // ---------------------------------------------------------------------
    // OAuth2 client-credentials token, fetched once per run and reused.
    // Fetching per scenario would make the suite's own load the dominant
    // traffic against the identity provider and would distort any rate-limit
    // assertion downstream.
    // ---------------------------------------------------------------------
    if (config.tokenUrl && config.clientId) {
        var tokenResponse = karate.call('classpath:helpers/get-token.feature', config);
        config.accessToken = tokenResponse.accessToken;
    } else {
        karate.log('No token URL configured — running unauthenticated (local mode).');
        config.accessToken = null;
    }

    return config;
}
