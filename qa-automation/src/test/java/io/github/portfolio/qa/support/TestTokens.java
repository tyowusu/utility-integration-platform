package io.github.portfolio.qa.support;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;

import java.time.Instant;
import java.util.Base64;
import java.util.Date;

/**
 * Adversarial JWTs for gateway policy testing.
 *
 * <p>Every token here is minted at call time rather than read from a fixture
 * file. A checked-in expired token stops being interesting the moment someone
 * asks "is this still expired?" and starts being a maintenance liability; a
 * token built now with a past {@code exp} is expired on every run, forever,
 * and needs no upkeep.
 *
 * <p>Shared by the Karate feature files (via {@code Java.type(...)}) and the
 * REST Assured suites, so the two agree on exactly what "forged" means.
 *
 * <h2>Why RS256 and not HS256</h2>
 *
 * <p>These tokens are aimed at a policy that validates RS256 signatures
 * against the identity provider's published JWKS. A token signed with HS256
 * is rejected on the algorithm before its signature is ever checked — so an
 * HS256 "forged" token proves only that the policy dislikes HS256, not that
 * it verifies signatures. Likewise the issuer and audience below must match
 * what the provider really issues, or every token is rejected on a claim
 * mismatch and the interesting check is never reached.
 *
 * <p>That distinction matters: a test that passes for the wrong reason is
 * worse than no test, because it reports coverage it does not have.
 *
 * <h2>What these can and cannot isolate</h2>
 *
 * <p>{@link #forged()} and {@link #algNone()} isolate exactly one defect
 * each — an unknown signing key, and the {@code alg=none} bypass.
 *
 * <p>{@link #expired()} and {@link #wrongAudience()} cannot. Producing a
 * token that is correctly signed *and* expired would require the provider's
 * private key, which is the whole point of asymmetric signing. They are
 * therefore signed with the same unknown key, and a rejection may be due to
 * the signature rather than the claim under test. They still assert something
 * worth asserting — these tokens must never be accepted — but they do not on
 * their own prove that {@code exp} and {@code aud} are evaluated. Proving
 * that needs a genuinely issued token, obtained for a different audience or
 * left to expire.
 */
public final class TestTokens {

    /**
     * Issuer and audience must match what the identity provider actually
     * mints, so that rejection is attributable to the defect under test
     * rather than to a claim mismatch. Overridable so the suite is not
     * welded to one tenant.
     */
    private static final String ISSUER =
            System.getProperty("jwt.issuer", "https://dev-y07kpoe8c074nk6q.us.auth0.com/");

    private static final String AUDIENCE =
            System.getProperty("jwt.audience", "switching-experience-api");

    /**
     * An RSA key the gateway has never seen, generated fresh per JVM. The
     * key ID is deliberately absent from the provider's JWKS, so a token
     * signed with it is well-formed, correctly algorithm'd, and verifiable
     * only against a key the gateway cannot obtain.
     */
    private static final RSAKey UNKNOWN_KEY = generateUnknownKey();

    private TestTokens() {
    }

    private static RSAKey generateUnknownKey() {
        try {
            return new RSAKeyGenerator(2048)
                    .keyID("attacker-key-absent-from-jwks")
                    .generate();
        } catch (JOSEException e) {
            throw new IllegalStateException("Could not generate test signing key", e);
        }
    }

    private static JWTClaimsSet.Builder baseClaims() {
        return new JWTClaimsSet.Builder()
                .subject("portal-client")
                .issuer(ISSUER)
                .audience(AUDIENCE)
                .claim("scope", "switching.read switching.write");
    }

    private static String sign(JWTClaimsSet claims) {
        try {
            SignedJWT jwt = new SignedJWT(
                    new JWSHeader.Builder(JWSAlgorithm.RS256)
                            .keyID(UNKNOWN_KEY.getKeyID())
                            .build(),
                    claims);
            jwt.sign(new RSASSASigner(UNKNOWN_KEY));
            return jwt.serialize();
        } catch (JOSEException e) {
            throw new IllegalStateException("Could not mint test token", e);
        }
    }

    /**
     * Expired an hour ago. Also signed with an unknown key — see the class
     * note on what this can and cannot isolate.
     */
    public static String expired() {
        return sign(baseClaims()
                .issueTime(Date.from(Instant.now().minusSeconds(7200)))
                .expirationTime(Date.from(Instant.now().minusSeconds(3600)))
                .build());
    }

    /**
     * The signature test. Correct issuer, correct audience, correct
     * algorithm, comfortably unexpired — and signed with a key the gateway
     * has no way to obtain. A policy that reads claims without verifying the
     * signature accepts this and passes every other test in the class.
     */
    public static String forged() {
        return sign(baseClaims()
                .issueTime(Date.from(Instant.now().minusSeconds(60)))
                .expirationTime(Date.from(Instant.now().plusSeconds(3600)))
                .build());
    }

    /**
     * The {@code alg=none} bypass: a header declaring no algorithm and an
     * empty signature segment. A library configured to honour the header's
     * algorithm choice will accept whatever claims the caller wrote.
     */
    public static String algNone() {
        Base64.Encoder b64 = Base64.getUrlEncoder().withoutPadding();
        String header = b64.encodeToString("{\"alg\":\"none\",\"typ\":\"JWT\"}".getBytes());
        String payload = b64.encodeToString(
                ("{\"sub\":\"portal-client\",\"iss\":\"" + ISSUER + "\",\"aud\":\"" + AUDIENCE
                        + "\",\"exp\":" + (Instant.now().getEpochSecond() + 3600) + "}").getBytes());
        return header + "." + payload + ".";
    }

    /**
     * Issued for a different API. Also signed with an unknown key — see the
     * class note on what this can and cannot isolate.
     */
    public static String wrongAudience() {
        return sign(baseClaims()
                .audience("some-other-api")
                .expirationTime(Date.from(Instant.now().plusSeconds(3600)))
                .build());
    }
}
