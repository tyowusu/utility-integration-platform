package io.github.portfolio.qa.restassured;

import io.restassured.RestAssured;
import io.restassured.builder.RequestSpecBuilder;
import io.restassured.filter.log.RequestLoggingFilter;
import io.restassured.filter.log.ResponseLoggingFilter;
import io.restassured.http.ContentType;
import io.restassured.specification.RequestSpecification;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;

import static io.restassured.module.jsv.JsonSchemaValidator.matchesJsonSchemaInClasspath;
import static org.hamcrest.Matchers.*;

/**
 * Contract conformance for the Switching Experience API.
 *
 * <p>Karate already covers the behaviour. What this class adds is
 * <em>schema</em> conformance: every response is validated against a JSON
 * Schema derived from the RAML, so an additive change in the application that
 * Karate's field-level assertions would tolerate — a renamed field, a number
 * that became a string, a nullable that started arriving null — fails here.
 *
 * <p>Named {@code *IT} so Failsafe runs it during {@code mvn verify}, after a
 * deployment, rather than Surefire running it during {@code mvn test} when
 * nothing is deployed.
 */
@DisplayName("Switching API — contract conformance")
class SwitchingContractIT {

    private static RequestSpecification spec;
    private static String effectiveDate;
    private static String midMonthDate;

    @BeforeAll
    static void setUp() {
        String baseUrl = System.getProperty("api.base.url", "https://localhost:8082");
        String basePath = System.getProperty("api.base.path", "/api");
        String token = System.getProperty("access.token", "");

        RequestSpecBuilder builder = new RequestSpecBuilder()
                .setBaseUri(baseUrl)
                .setBasePath(basePath)
                .setContentType(ContentType.JSON)
                .setAccept(ContentType.JSON)
                .addHeader("x-channel", "B2C_PORTAL");

        if (!token.isBlank()) {
            builder.addHeader("Authorization", "Bearer " + token);
        }

        // Log only on failure. Logging every request in CI buries the one
        // failure in thousands of lines and, worse, prints bearer tokens into
        // a build log that is retained far longer than the token is valid.
        builder.addFilter(new RequestLoggingFilter(io.restassured.filter.log.LogDetail.URI));
        builder.addFilter(new ResponseLoggingFilter(io.restassured.filter.log.LogDetail.STATUS));

        spec = builder.build();

        // Non-production environments use self-signed certificates.
        if (baseUrl.contains("localhost") || baseUrl.contains("-dev")) {
            RestAssured.useRelaxedHTTPSValidation();
        }

        // Two months ahead, first of the month: inside the submission window
        // on every calendar day, so the fixture cannot expire.
        effectiveDate = LocalDate.now().plusMonths(2).withDayOfMonth(1).toString();

        // Built with withDayOfMonth, not string replacement. A naive
        // "2026-01-01".replace("-01", "-15") substitutes the *month* segment
        // and produces "2026-15-01" — a defect that hides for eleven months
        // of the year and then fails every January.
        midMonthDate = LocalDate.now().plusMonths(2).withDayOfMonth(15).toString();
    }

    private static String uniquePdr() {
        String millis = String.valueOf(System.currentTimeMillis());
        return "9" + millis.substring(millis.length() - 13);
    }

    @Test
    @DisplayName("202 response conforms to the SwitchingAccepted schema")
    void acceptedResponseMatchesSchema() {
        io.restassured.RestAssured.given().spec(spec)
                .body("""
                      {
                        "pdr": "%s",
                        "customerType": "RESIDENTIAL",
                        "fiscalCode": "RSSMRA80A01H501U",
                        "firstName": "Mario",
                        "lastName": "Rossi",
                        "effectiveDate": "%s"
                      }
                      """.formatted(uniquePdr(), effectiveDate))
                .when()
                .post("/switching-requests")
                .then()
                .statusCode(202)
                .body(matchesJsonSchemaInClasspath("schemas/switching-accepted.schema.json"))
                .body("status", equalTo("SUBMITTED"))
                .body("requestId", not(emptyOrNullString()))
                // outcomeExpectedBy is what the portal renders to the customer.
                // If it is absent the portal shows nothing, and the customer
                // calls to ask — which is the cost this field exists to avoid.
                .body("outcomeExpectedBy", not(emptyOrNullString()));
    }

    @Test
    @DisplayName("422 response conforms to the Error schema and names a reason")
    void notAdmissibleResponseMatchesSchema() {
        io.restassured.RestAssured.given().spec(spec)
                .body("""
                      {
                        "pdr": "%s",
                        "customerType": "RESIDENTIAL",
                        "fiscalCode": "RSSMRA80A01H501U",
                        "effectiveDate": "%s"
                      }
                      """.formatted(uniquePdr(), midMonthDate))
                .when()
                .post("/switching-requests")
                .then()
                .statusCode(422)
                .body(matchesJsonSchemaInClasspath("schemas/error.schema.json"))
                .body("error.correlationId", not(emptyOrNullString()))
                // The generic fallback message means the error handler fell
                // through to ANY rather than matching SWITCHING:NOT_ADMISSIBLE
                // — a regression that leaves the customer with no explanation.
                .body("error.message", not(equalTo("An unexpected error occurred.")));
    }

    @Test
    @DisplayName("404 response conforms to the Error schema")
    void notFoundResponseMatchesSchema() {
        io.restassured.RestAssured.given().spec(spec)
                .when()
                .get("/switching-requests/{id}", "SII-REQ-DOES-NOT-EXIST-0000")
                .then()
                .statusCode(404)
                .body(matchesJsonSchemaInClasspath("schemas/error.schema.json"));
    }

    @Test
    @DisplayName("Downstream infrastructure detail never reaches the caller")
    void errorResponsesAreSanitised() {
        io.restassured.RestAssured.given().spec(spec)
                .body("""
                      {
                        "pdr": "%s",
                        "customerType": "RESIDENTIAL",
                        "fiscalCode": "RSSMRA80A01H501U",
                        "effectiveDate": "%s"
                      }
                      """.formatted(uniquePdr(), midMonthDate))
                .when()
                .post("/switching-requests")
                .then()
                .statusCode(422)
                // SII fault strings can carry hostnames and internal
                // identifiers. They belong in the audit log, which is retained
                // under the Seller's policy and access-controlled — not in a
                // response body that reaches a browser.
                .body("error.message", not(containsString("internal")))
                .body("error.message", not(containsString(".local")))
                .body("error.message", not(containsString("Exception")))
                .body("$", not(hasKey("stackTrace")));
    }

    @Test
    @DisplayName("Eligibility response conforms to its schema")
    void eligibilityResponseMatchesSchema() {
        io.restassured.RestAssured.given().spec(spec)
                .when()
                .get("/supply-points/{pdr}/eligibility", "12345678901234")
                .then()
                .statusCode(200)
                .body(matchesJsonSchemaInClasspath("schemas/eligibility.schema.json"))
                .body("currentWindow.deadlineDay", equalTo(10))
                .body("availableDates", not(empty()));
    }
}
