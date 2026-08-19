package io.github.portfolio.qa.support;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.MACSigner;
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
 */
public final class TestTokens {

    /**
     * A key the gateway has never seen. Length is above the HS256 minimum so
     * that signing succeeds — the point is a valid signature made with the
     * wrong key, not a signature that fails to construct.
     */
    private static final String UNKNOWN_KEY =
            "an-attacker-controlled-signing-key-of-sufficient-length!!";

    private TestTokens() {
    }

    private static JWTClaimsSet.Builder baseClaims() {
        return new JWTClaimsSet.Builder()
                .subject("portal-client")
                .issuer("https://identity.example.com")
                .audience("switching-experience-api")
                .claim("scope", "switching.read switching.write");
    }

    private static String sign(JWTClaimsSet claims) {
        try {
            SignedJWT jwt = new SignedJWT(new JWSHeader(JWSAlgorithm.HS256), claims);
            jwt.sign(new MACSigner(UNKNOWN_KEY.getBytes()));
            return jwt.serialize();
        } catch (JOSEException e) {
            throw new IllegalStateException("Could not mint test token", e);
        }
    }

    /** Well-formed, correctly signed for its issuer — but expired an hour ago. */
    public static String expired() {
        return sign(baseClaims()
                .issueTime(Date.from(Instant.now().minusSeconds(7200)))
                .expirationTime(Date.from(Instant.now().minusSeconds(3600)))
                .build());
    }

    /** Valid in every respect except that the signing key is unknown to the gateway. */
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
                ("{\"sub\":\"portal-client\",\"aud\":\"switching-experience-api\",\"exp\":"
                        + (Instant.now().getEpochSecond() + 3600) + "}").getBytes());
        return header + "." + payload + ".";
    }

    /** Correctly signed and unexpired, but issued for a different API. */
    public static String wrongAudience() {
        return sign(baseClaims()
                .audience("some-other-api")
                .expirationTime(Date.from(Instant.now().plusSeconds(3600)))
                .build());
    }
}
