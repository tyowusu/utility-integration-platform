%dw 2.0
output application/json skipNullOn = "everywhere"

/**
 * ============================================================================
 * SII REQUEST STATUS → CANONICAL
 * ============================================================================
 *
 * Serves GET /switching-requests/{requestId} for the portals and for agents
 * in Salesforce.
 *
 * The status vocabulary is deliberately small and channel-neutral. SII and
 * distributor systems expose a wider, more granular set of internal states;
 * exposing those directly would couple every front end to the regulated
 * protocol and force each one to reimplement the same interpretation.
 * ============================================================================
 */

var body = payload.StatoRichiesta default payload

var rawState = upper((body.Stato default "") as String)

/**
 * Collapse the protocol's internal states onto four the customer understands.
 * "Where is my switch?" has four honest answers: we've sent it, they're
 * looking at it, it's approved, it's refused.
 */
var STATE_MAP = {
    "INVIATA": "SUBMITTED",
    "PRESA_IN_CARICO": "SUBMITTED",
    "IN_VALUTAZIONE": "UNDER_REVIEW",
    "IN_LAVORAZIONE": "UNDER_REVIEW",
    "AMMISSIBILE": "ACCEPTED",
    "ESEGUITA": "ACCEPTED",
    "NON_AMMISSIBILE": "REJECTED",
    "RIFIUTATA": "REJECTED",
    "ANNULLATA": "CANCELLED"
}

---
{
    requestId: body.CodiceRichiesta default vars.requestId,
    pdr: body.PDR default null,
    effectiveDate: body.DecorrenzaSwitching default null,

    status: STATE_MAP[rawState] default "UNKNOWN",

    // Retained alongside the simplified status so support staff can reconcile
    // against SII without a second lookup.
    protocolStatus: rawState,

    submittedAt: body.DataRichiesta default null,
    lastUpdatedAt: body.DataUltimoAggiornamento default null,

    (rejection: {
        reasonCode: body.CodiceEsito,
        reasonText: body.DescrizioneEsito
    }) if (STATE_MAP[rawState] == "REJECTED"),

    regulatoryBasis: "Delibera ARERA 77/2018/R/com"
}
