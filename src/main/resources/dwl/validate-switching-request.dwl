%dw 2.0
output application/java

/**
 * ============================================================================
 * REGULATORY VALIDATION — switching (cambio venditore), gas
 * ============================================================================
 *
 * Encodes the admissibility conditions for a switching request before it is
 * submitted to the SII.
 *
 * PRIMARY RULE — Delibera 77/2018/R/com
 * ------------------------------------
 * The resolution maintains the existing provision that the switching
 * effective date must coincide with the FIRST DAY OF THE MONTH, and that the
 * request must be submitted BY THE 10th DAY OF THE PRECEDING MONTH.
 *
 * Worked example: for supply to start on 1 September, the request must reach
 * SII no later than 10 August. On 11 August the earliest available effective
 * date becomes 1 October.
 *
 * The resolution explicitly defers to future provisions the definition of
 * procedures allowing switching on any day of the month. When that change is
 * made, it lands here — which is the reason this rule is isolated in a
 * versioned module rather than inlined in flow logic.
 *
 * WHY VALIDATE LOCALLY AT ALL
 * ---------------------------
 * SII would reject an out-of-window request itself. Rejecting it here is
 * nonetheless worthwhile: rejected requests count against the Seller in
 * ARERA commercial-quality reporting, and a locally-rejected request can be
 * explained to the customer immediately, with the next valid date offered.
 *
 * SCOPE NOTE
 * ----------
 * Switching applies to electricity and gas, the markets covered by the SII
 * under Law 129/2010. It has no water equivalent: the Italian integrated
 * water service is a territorial monopoly per ATO with no retail competition,
 * so there is no supplier to switch to. Water processes in this platform are
 * billing, metering and commercial quality only. See ADR-0002.
 * ============================================================================
 */

// ---------------------------------------------------------------------------
// Reference data
// ---------------------------------------------------------------------------

var today = now() as Date

// Gas PDR (Punto di Riconsegna): exactly 14 numeric digits.
var PDR_PATTERN = /^[0-9]{14}$/

// Codice fiscale (natural person): 16 alphanumeric characters.
var CF_PATTERN = /^[A-Z0-9]{16}$/

// Partita IVA (legal entity): 11 numeric digits.
var PIVA_PATTERN = /^[0-9]{11}$/

var SUBMISSION_DEADLINE_DAY = 10

// ---------------------------------------------------------------------------
// Regulatory calendar
// ---------------------------------------------------------------------------

/**
 * The submission deadline governing a given effective date: day 10 of the
 * month immediately preceding it.
 */
fun submissionDeadlineFor(effectiveDate: Date): Date =
    (((effectiveDate - |P1M|) as String {format: "yyyy-MM"})
        ++ "-" ++ (SUBMISSION_DEADLINE_DAY as String {format: "00"}))
    as Date {format: "yyyy-MM-dd"}

/**
 * The earliest effective date still reachable from a given submission date.
 *
 * On or before the 10th, next month's first day is still available.
 * From the 11th, it is not, and the earliest becomes the month after.
 */
fun earliestEffectiveDateFrom(submissionDate: Date): Date = do {
    var dayOfMonth = (submissionDate as String {format: "d"}) as Number
    var monthsAhead = if (dayOfMonth <= SUBMISSION_DEADLINE_DAY) 1 else 2
    ---
    (((submissionDate + (("P" ++ (monthsAhead as String) ++ "M") as Period)) as String {format: "yyyy-MM"}) ++ "-01")
        as Date {format: "yyyy-MM-dd"}
}

fun isFirstOfMonth(d: Date): Boolean =
    ((d as String {format: "d"}) as Number) == 1

// ---------------------------------------------------------------------------
// Field-level checks
// ---------------------------------------------------------------------------

var pdr = payload.pdr default ""
var customerType = upper(payload.customerType default "")
var fiscalCode = upper(payload.fiscalCode default "")

var parsedEffectiveDate =
    payload.effectiveDate default null

var effectiveDate =
    if (parsedEffectiveDate != null)
        (parsedEffectiveDate as Date) // throws if malformed; APIKit type-checks first
    else
        null

var structuralErrors =
    []
    ++ (if (not (pdr matches PDR_PATTERN))
            ["pdr must be exactly 14 numeric digits"] else [])
    ++ (if (not (customerType == "RESIDENTIAL" or customerType == "BUSINESS"))
            ["customerType must be RESIDENTIAL or BUSINESS"] else [])
    ++ (if (customerType == "RESIDENTIAL" and not (fiscalCode matches CF_PATTERN))
            ["fiscalCode must be a valid 16-character codice fiscale for a residential customer"] else [])
    ++ (if (customerType == "BUSINESS" and not (fiscalCode matches PIVA_PATTERN))
            ["fiscalCode must be a valid 11-digit partita IVA for a business customer"] else [])
    ++ (if (effectiveDate == null)
            ["effectiveDate is required"] else [])

// ---------------------------------------------------------------------------
// Regulatory checks — only meaningful once the date parses
// ---------------------------------------------------------------------------

var regulatoryErrors =
    if (effectiveDate == null) []
    else
        []
        ++ (if (not isFirstOfMonth(effectiveDate))
                ["effectiveDate must be the first day of a month (Delibera 77/2018/R/com)"]
            else [])
        ++ (if (isFirstOfMonth(effectiveDate) and today > submissionDeadlineFor(effectiveDate))
                ["the submission window for this effectiveDate closed on "
                    ++ (submissionDeadlineFor(effectiveDate) as String {format: "yyyy-MM-dd"})
                    ++ "; the earliest available effectiveDate is now "
                    ++ (earliestEffectiveDateFrom(today) as String {format: "yyyy-MM-dd"})]
            else [])
        ++ (if (effectiveDate <= today)
                ["effectiveDate must be in the future"] else [])

var allErrors = structuralErrors ++ regulatoryErrors

// ---------------------------------------------------------------------------
// Result
// ---------------------------------------------------------------------------

---
{
    valid: sizeOf(allErrors) == 0,
    errors: allErrors,

    normalisedEffectiveDate:
        if (effectiveDate != null)
            effectiveDate as String {format: "yyyy-MM-dd"}
        else null,

    /*
     * Communicated to the caller on acceptance so the portal can set the
     * customer's expectation. Under Delibera 77/2018/R/com the distributor
     * transmits the admissibility flow within 1 working day of the SII
     * notification, and an inadmissibility flow within 2 working days.
     *
     * Three calendar days is a deliberately conservative customer-facing
     * translation of "2 working days" — it absorbs a weekend without
     * promising more precision than the regulation guarantees.
     */
    outcomeExpectedBy:
        if (sizeOf(allErrors) == 0)
            (today + |P3D|) as String {format: "yyyy-MM-dd"}
        else null,

    earliestAvailableEffectiveDate:
        earliestEffectiveDateFrom(today) as String {format: "yyyy-MM-dd"}
}
