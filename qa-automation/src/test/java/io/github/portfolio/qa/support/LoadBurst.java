package io.github.portfolio.qa.support;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Semaphore;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Concurrent load generator for the rate-limiting scenario.
 *
 * <h2>Why this exists rather than a loop in the feature file</h2>
 *
 * The burst was a sequential {@code karate.call} loop. Sequential load is
 * bounded by round-trip time, not by the server: at ~430ms per request from a
 * developer laptop that is roughly 140 requests per minute, so a 200/minute
 * limit cannot be exceeded at all, whatever the loop count. The same loop
 * managed ~110ms per request on a CI runner sitting near the region and
 * exceeded the limit easily.
 *
 * <p>So the assertion passed or failed on network latency. A test that
 * reports "rate limiting is broken" when the tester is far from the server —
 * and would silently stop proving anything the day a runner got slower — is
 * measuring the wrong thing.
 *
 * <p>Firing concurrently decouples throughput from latency: 300 requests at a
 * concurrency of 25 complete in roughly the time 12 sequential ones would, so
 * the window is exceeded regardless of where the test runs.
 *
 * <h2>What it deliberately does not do</h2>
 *
 * No retries, no backoff, no failure on non-2xx. Every status is counted and
 * returned, because 429 is the expected outcome for most of a burst and the
 * caller decides what the distribution means.
 */
public final class LoadBurst {

    private LoadBurst() {
    }

    /**
     * Fires {@code count} GETs at {@code url} with the given bearer token and
     * returns a status-code histogram keyed by status as a String, so that
     * Karate can read it as {@code counts['429']}.
     *
     * <p>Transport failures are counted under {@code "error"} rather than
     * thrown: a burst that half-fails still carries information, and an
     * exception here would surface as a Karate error naming this class instead
     * of the gateway behaviour under test.
     *
     * @param url         fully-qualified endpoint
     * @param token       bearer token, without the "Bearer " prefix
     * @param count       total requests to issue
     * @param concurrency maximum requests in flight at once
     */
    public static Map<String, Integer> fire(String url, String token, int count, int concurrency) {
        Map<String, AtomicInteger> tally = new ConcurrentHashMap<>();

        // The client gets its own threads, deliberately.
        //
        // The first version handed HttpClient the same fixed pool the request
        // tasks ran on and used the blocking send(). All pool threads then sat
        // inside send() waiting for responses, leaving the client's executor
        // with nothing to run connection completion on — every one of 300
        // requests failed with "HTTP connect timed out" while the network was
        // perfectly healthy. sendAsync never blocks a thread waiting, so the
        // starvation cannot recur.
        HttpClient client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .build();

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(url))
                .header("Authorization", "Bearer " + token)
                .timeout(Duration.ofSeconds(20))
                .GET()
                .build();

        // Bounds requests in flight. Firing all 300 at once would measure
        // connection-pool behaviour rather than the gateway policy.
        Semaphore inFlight = new Semaphore(concurrency);
        CompletableFuture<?>[] all = new CompletableFuture<?>[count];

        for (int i = 0; i < count; i++) {
            try {
                inFlight.acquire();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                record(tally, "error:interrupted");
                all[i] = CompletableFuture.completedFuture(null);
                continue;
            }
            all[i] = client.sendAsync(request, HttpResponse.BodyHandlers.discarding())
                    .handle((response, error) -> {
                        try {
                            if (error != null) {
                                // The exception type is part of the key. A bare
                                // "error" count says a burst failed without
                                // saying whether it was TLS, DNS, a timeout or
                                // a refused connection, and those need entirely
                                // different fixes.
                                Throwable root = error;
                                while (root.getCause() != null) {
                                    root = root.getCause();
                                }
                                record(tally, "error:" + root.getClass().getSimpleName()
                                        + ":" + String.valueOf(root.getMessage()));
                            } else {
                                record(tally, String.valueOf(response.statusCode()));
                            }
                        } finally {
                            inFlight.release();
                        }
                        return null;
                    });
        }
        CompletableFuture.allOf(all).join();

        Map<String, Integer> counts = new HashMap<>();
        tally.forEach((status, n) -> counts.put(status, n.get()));
        return counts;
    }

    private static void record(Map<String, AtomicInteger> tally, String key) {
        tally.computeIfAbsent(key, k -> new AtomicInteger()).incrementAndGet();
    }
}
