%dw 2.0
output application/json

/**
 * ============================================================================
 * SWITCHING ELIGIBILITY CALENDAR
 * ============================================================================
 *
 * Serves the portals' pre-flight check: given today's date, which effective
 * dates can a customer actually choose?
 *
 * Exists because the regulatory calendar is counter-intuitive to customers.
 * Someone starting a switch on 12 July cannot have supply from 1 August —
 * the window closed on 10 July — and discovering that only after completing
 * a form is a reliable source of abandoned journeys and contact-centre calls.
 *
 * Returning the calendar up front lets the front end render a date picker
 * with the invalid options already disabled.
 * ============================================================================
 */

var today = now() as Date
var SUBMISSION_DEADLINE_DAY = 10
var HORIZON_MONTHS = 6

fun firstOfMonthAhead(base: Date, monthsAhead: Number): Date =
    (((base + (("P" ++ (monthsAhead as String) ++ "M") as Period)) as String {format: "yyyy-MM"}) ++ "-01")
        as Date {format: "yyyy-MM-dd"}

fun submissionDeadlineFor(effectiveDate: Date): Date =
    (((effectiveDate - |P1M|) as String {format: "yyyy-MM"})
        ++ "-" ++ (SUBMISSION_DEADLINE_DAY as String {format: "00"}))
    as Date {format: "yyyy-MM-dd"}

var dayOfMonth = (today as String {format: "d"}) as Number
var windowOpenForNextMonth = dayOfMonth <= SUBMISSION_DEADLINE_DAY

// Offer a rolling horizon rather than a single date: business customers in
// particular schedule switches around contract anniversaries and want to
// choose a month further out.
var availableDates =
    (1 to HORIZON_MONTHS) map ((monthsAhead) -> do {
        var effective = firstOfMonthAhead(today, monthsAhead)
        var deadline = submissionDeadlineFor(effective)
        ---
        {
            effectiveDate: effective as String {format: "yyyy-MM-dd"},
            submissionDeadline: deadline as String {format: "yyyy-MM-dd"},
            available: today <= deadline
        }
    })

---
{
    pdr: vars.pdr,
    evaluatedAt: today as String {format: "yyyy-MM-dd"},

    earliestAvailableEffectiveDate:
        firstOfMonthAhead(today, if (windowOpenForNextMonth) 1 else 2)
            as String {format: "yyyy-MM-dd"},

    currentWindow: {
        deadlineDay: SUBMISSION_DEADLINE_DAY,
        openForNextMonth: windowOpenForNextMonth,
        note: if (windowOpenForNextMonth)
                  "The window for next month's first day is open until day "
                      ++ SUBMISSION_DEADLINE_DAY ++ " of this month."
              else
                  "The window for next month's first day has closed. The earliest "
                      ++ "selectable effective date is the month after next."
    },

    availableDates: availableDates,

    // Echoed back so the portal can show the customer whether the date they
    // had in mind is actually reachable, rather than silently substituting one.
    requestedDateAssessment:
        if (vars.requestedEffectiveDate != null) do {
            var requested = vars.requestedEffectiveDate as Date {format: "yyyy-MM-dd"}
            var deadline = submissionDeadlineFor(requested)
            ---
            {
                requestedEffectiveDate: vars.requestedEffectiveDate,
                isFirstOfMonth: ((requested as String {format: "d"}) as Number) == 1,
                submissionDeadline: deadline as String {format: "yyyy-MM-dd"},
                available: today <= deadline
                    and ((requested as String {format: "d"}) as Number) == 1
            }
        } else null,

    regulatoryBasis: "Delibera ARERA 77/2018/R/com"
}
