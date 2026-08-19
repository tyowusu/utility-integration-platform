package io.github.portfolio.qa.karate;

import com.intuit.karate.junit5.Karate;

/**
 * Functional and regression suite for the Switching Experience API.
 *
 * <p>Split into three entry points rather than one, because they have
 * different preconditions and different blast radius:
 *
 * <ul>
 *   <li>{@link #functional()} — the full suite. Writes real switching
 *       requests, so it runs against dev and test only.</li>
 *   <li>{@link #smoke()} — read-only. Safe against production, and used as
 *       the post-deployment gate before a production release is marked
 *       successful.</li>
 *   <li>{@link #gateway()} — policy enforcement at the API Manager layer.
 *       Requires a deployed, autodiscovered application; meaningless against
 *       a runtime started from Anypoint Studio, which has no gateway in
 *       front of it.</li>
 * </ul>
 *
 * <p>Running everything as one suite would mean either never running it
 * against production or running writes against production. Neither is
 * acceptable, so the split is structural rather than a matter of discipline.
 */
class SwitchingFunctionalTest {

    @Karate.Test
    Karate functional() {
        return Karate.run("classpath:features/switching")
                .tags("@functional")
                .relativeTo(getClass());
    }

    @Karate.Test
    Karate smoke() {
        // @readonly is the guarantee that matters here: no scenario in this
        // selection transmits anything to SII.
        return Karate.run("classpath:features/switching")
                .tags("@smoke", "@readonly")
                .relativeTo(getClass());
    }

    @Karate.Test
    Karate gateway() {
        return Karate.run("classpath:features/gateway")
                .tags("@gateway")
                .relativeTo(getClass());
    }
}
