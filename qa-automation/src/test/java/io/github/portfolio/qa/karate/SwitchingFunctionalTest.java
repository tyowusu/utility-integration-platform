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

    /**
     * The blocking functional suite: everything the application can answer on
     * its own, plus everything the gateway refuses before a downstream call is
     * made. Green here is a real statement about the code.
     *
     * ~@requires-downstream excludes the scenarios that cannot pass until SII,
     * Salesforce, billing and the identity provider have stand-ins. Those are
     * not weaker tests — they cover submission, status and duplicate detection,
     * which is the core of the regulated flow — they are simply unrunnable
     * against an environment whose downstream hosts do not resolve. They run
     * separately, in {@link #mocksRequired()}, so their absence is visible
     * rather than buried in a permanently red suite that everyone learns to
     * ignore.
     */
    @Karate.Test
    Karate functional() {
        return Karate.run("classpath:features/switching")
                .tags("@functional", "~@requires-downstream")
                .relativeTo(getClass());
    }

    /**
     * The complement of {@link #functional()}: only the scenarios that need
     * downstream stand-ins. Expected to fail with 504 CONNECTIVITY until the
     * mocks exist. Run as an informational job, never as a merge gate — a
     * failure here says nothing about the change under test.
     */
    @Karate.Test
    Karate mocksRequired() {
        return Karate.run("classpath:features/switching")
                .tags("@functional", "@requires-downstream")
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
