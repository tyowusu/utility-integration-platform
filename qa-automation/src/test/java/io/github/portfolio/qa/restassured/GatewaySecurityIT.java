package io.github.portfolio.qa.restassured;

import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.MACSigner;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import io.restassured.RestAssured;
import io.restassured.builder.RequestSpecBuilder;
import io.restassured.http.ContentType;
import io.restassured.response.Response;
import io.restassured.specification.RequestSpecification;
import org.junit.jupiter.api.*;

import java.time.Instant;
import java.util.Date;
import java.util.List;
import java.util.concurrent.*;
import java.util.stream.IntStream;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Gateway-layer authorization and throttling.
 *
 * <p>Everything here is deliberately black-box and hostile. The suite mints
 * its own tokens so it can produce cases a cooperating identity provider will
 * never hand out: expired, unsigned, algorithm-confused, wrong-audience.
 *
 * <p>The reason to mint rather than to request is that a JWT validation policy
 * has a specific and well-known family of bypasses, and each of them requires
 * a token no legitimate issuer would produce. Testing only with real tokens
 * proves the happy path and nothing else.
 */
@DisplayName("API Gateway — authorization and throttling")
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class GatewaySecurityIT {

    private static RequestSpecification spec;
    private static String validToken;
    private static final String WRONG_KEY = "an-attacker-controlled-signing-key-of-sufficient-length!!";

    @BeforeAll
    static void setUp() {
        String baseUrl = System.getProperty("api.base.url", "https://localhost:8082");
        String basePath = System.getProperty("api.base.path", "/api");
        validToken = System.getProperty("access.token", "");

        spec = new RequestSpecBuilder()
                .setBaseUri(baseUrl)
                .setBasePath(basePath)
                .setAccept(ContentType.JSON)
                .build();

        if (baseUrl.contains("localhost") || baseUrl.contains("-dev")) {
            RestAssured.useRelaxedHTTPSValidation();
        }
    }

    private static String mintToken(String subject, Instant expiry, String signingKey, JWSAlgorithm alg)
            throws JOSEException {
        JWTClaimsSet claims = new JWTClaimsSet.Builder()
                .subject(subject)
                .issuer("https://identity.example.com")
                .audience("switching-experience-api")
                .issueTime(Date.from(Instant.now().minusSeconds(60)))
                .expirationTime(Date.from(expiry))
                .claim("scope", "switching.write switching.read")
                .build();

        SignedJWT jwt = new SignedJWT(new JWSHeader(alg), claims);
        jwt.sign(new MACSigner(signingKey.getBytes()));
        return jwt.serialize();
    }

    private Response callEligibility(String authHeader) {
        RequestSpecification req = RestAssured.given().spec(spec);
        if (authHeader != null) {
            req = req.header("Authorization", authHeader);
        }
        return req.when().get("/supply-points/{pdr}/eligibility", "12345678901234");
    }

    // ------------------------------------------------------------------
    // Authentication
    // ------------------------------------------------------------------

    @Test
    @Order(1)
    @DisplayName("Policies are bound: an anonymous request is refused")
    void anonymousRequestIsRefused() {
        int status = callEligibility(null).statusCode();

        // This assertion doubles as an autodiscovery health check. If the
        // application deployed but failed to bind to its API Manager instance,
        // it serves traffic ungoverned and this returns 200 — the one failure
        // mode that produces no error anywhere in the logs.
        //
        // 400 is an accepted refusal: a *missing* token is answered by the JWT
        // validation policy with 400 {"error": "JWT Token is required."}, while
        // a malformed or unsigned one returns 401. What matters here is that
        // the gateway refused, not which refusal it chose.
        assertTrue(status == 400 || status == 401 || status == 403,
                "Expected the gateway to refuse an anonymous request but got " + status
                        + ". If this is 200, API Manager autodiscovery did not bind: check that "
                        + "api.id matches the API instance in this environment and that "
                        + "anypoint.platform.client_id/secret were supplied at deploy time. "
                        + "If this is an empty 503, autodiscovery bound to an instance that does "
                        + "not exist — check api.id for a typo. If this is 502, the ingress "
                        + "cannot reach the application at all: see lastMileSecurity in pom.xml.");
    }

    @Test
    @Order(2)
    @DisplayName("A malformed bearer token is refused")
    void malformedTokenIsRefused() {
        int status = callEligibility("Bearer not.a.valid.jwt").statusCode();
        assertTrue(status == 401 || status == 403, "Expected 401/403, got " + status);
    }

    @Test
    @Order(3)
    @DisplayName("An expired token is refused")
    void expiredTokenIsRefused() throws JOSEException {
        String expired = mintToken("portal-client", Instant.now().minusSeconds(3600),
                WRONG_KEY, JWSAlgorithm.HS256);

        int status = callEligibility("Bearer " + expired).statusCode();
        assertTrue(status == 401 || status == 403, "Expected 401/403, got " + status);
    }

    @Test
    @Order(4)
    @DisplayName("A token signed with an unknown key is refused")
    void forgedSignatureIsRefused() throws JOSEException {
        String forged = mintToken("portal-client", Instant.now().plusSeconds(3600),
                WRONG_KEY, JWSAlgorithm.HS256);

        // Unexpired, well-formed, correct claims — only the signature is wrong.
        // A policy that parses claims without verifying the signature accepts
        // this, and every other test in this class still passes.
        int status = callEligibility("Bearer " + forged).statusCode();
        assertTrue(status == 401 || status == 403,
                "A token signed with an unknown key was accepted (" + status
                        + "). The JWT policy is parsing claims without verifying the signature.");
    }

    @Test
    @Order(5)
    @DisplayName("An unsigned (alg=none) token is refused")
    void algNoneTokenIsRefused() {
        // Hand-assembled: {"alg":"none","typ":"JWT"} with an empty signature.
        String header = java.util.Base64.getUrlEncoder().withoutPadding()
                .encodeToString("{\"alg\":\"none\",\"typ\":\"JWT\"}".getBytes());
        String payload = java.util.Base64.getUrlEncoder().withoutPadding()
                .encodeToString(("{\"sub\":\"portal-client\",\"exp\":"
                        + (Instant.now().getEpochSecond() + 3600) + "}").getBytes());
        String noneToken = header + "." + payload + ".";

        int status = callEligibility("Bearer " + noneToken).statusCode();
        assertTrue(status == 401 || status == 403,
                "An alg=none token was accepted (" + status + "). This is the classic JWT bypass.");
    }

    @Test
    @Order(6)
    @DisplayName("A token for a different audience is refused")
    void wrongAudienceIsRefused() throws JOSEException {
        JWTClaimsSet claims = new JWTClaimsSet.Builder()
                .subject("portal-client")
                .issuer("https://identity.example.com")
                .audience("some-other-api")
                .expirationTime(Date.from(Instant.now().plusSeconds(3600)))
                .build();
        SignedJWT jwt = new SignedJWT(new JWSHeader(JWSAlgorithm.HS256), claims);
        jwt.sign(new MACSigner(WRONG_KEY.getBytes()));

        int status = callEligibility("Bearer " + jwt.serialize()).statusCode();
        assertTrue(status == 401 || status == 403, "Expected 401/403, got " + status);
    }

    // ------------------------------------------------------------------
    // Throttling
    // ------------------------------------------------------------------

    @Test
    @Order(10)
    @DisplayName("Sustained load above the configured limit yields 429")
    void rateLimitIsEnforced() throws Exception {
        Assumptions.assumeFalse(validToken.isBlank(),
                "No access token supplied — skipping throttling assertions.");

        int requests = 60;
        ExecutorService pool = Executors.newFixedThreadPool(10);

        try {
            List<Future<Integer>> futures = IntStream.range(0, requests)
                    .mapToObj(i -> pool.submit(
                            () -> callEligibility("Bearer " + validToken).statusCode()))
                    .toList();

            long throttled = futures.stream().map(f -> {
                try {
                    return f.get(30, TimeUnit.SECONDS);
                } catch (Exception e) {
                    return -1;
                }
            }).filter(s -> s == 429).count();

            assertTrue(throttled > 0,
                    "No request was throttled across " + requests + " concurrent calls. "
                            + "Either the rate-limiting policy is not applied in this environment, "
                            + "or its threshold is set higher than this suite can reach — in which "
                            + "case the threshold is untested, not proven.");

            // A throttled request must be refused cleanly. A 500 under load
            // would send the portal into a retry loop that deepens the
            // overload instead of relieving it.
            long serverErrors = futures.stream().map(f -> {
                try {
                    return f.get(1, TimeUnit.SECONDS);
                } catch (Exception e) {
                    return -1;
                }
            }).filter(s -> s >= 500).count();

            assertEquals(0, serverErrors,
                    "Requests failed with 5xx under load. Throttling must refuse with 429, "
                            + "which clients back off from, not 5xx, which they retry.");
        } finally {
            pool.shutdownNow();
        }
    }

    @Test
    @Order(11)
    @DisplayName("A throttled response is a clean refusal, not a truncated body")
    void throttledResponseIsWellFormed() {
        Assumptions.assumeFalse(validToken.isBlank(), "No access token supplied.");

        Response r = callEligibility("Bearer " + validToken);
        Assumptions.assumeTrue(r.statusCode() == 429,
                "Not currently throttled — nothing to assert.");

        assertNotNull(r.getBody().asString());
        assertFalse(r.getBody().asString().isBlank(),
                "A 429 with an empty body gives the client nothing to log or surface.");
    }
}
