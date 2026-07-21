%dw 2.0
output application/java

/**
 * ============================================================================
 * SII SWITCHING OUTCOME → CANONICAL
 * ============================================================================
 *
 * Parses the asynchronous admissibility outcome returned by the distributor
 * via the SII, and translates regulatory reason codes into text a customer
 * can act on.
 *
 * Under Delibera 77/2018/R/com the distributor transmits the admissibility
 * flow within 1 working day of receiving the SII notification, and an
 * inadmissibility flow within 2 working days.
 *
 * SPECIFICATION FIDELITY: as with the request mapping, element names and
 * reason codes below are representative of the tracciato's shape. The
 * authoritative code list is published by Acquirente Unico and must be
 * reconciled against the current specification version before production use.
 * ============================================================================
 */

var body = payload.EsitoSwitching default payload

/**
 * Reason-code translation.
 *
 * The codes are regulatory; the text is ours. Two distinct audiences are
 * served deliberately:
 *
 *   reasonText  — customer-facing, plain language, actionable
 *   reasonCode  — retained verbatim for audit and for reconciliation against
 *                 SII records during a dispute
 *
 * Surfacing a bare code to a customer guarantees an inbound call. Discarding
 * it destroys the audit trail. Both are kept.
 */
var REASON_TEXT = {
    "01": "The supply point could not be found in the distributor's records.",
    "02": "The customer's fiscal code does not match the distributor's records for this supply point.",
    "03": "Another switching request is already in progress for this supply point.",
    "04": "The supply point is currently inactive and cannot be switched.",
    "05": "The request was received outside the regulatory submission window.",
    "06": "The outgoing supplier exercised its right of revocation.",
    "07": "The supply point is subject to a suspension for payment default."
}

var rawCode = (body.Esito.CodiceEsito default body.CodiceEsito default "") as String
var isAdmissible = rawCode == "00" or upper(body.Esito.Ammissibile default "") == "SI"

---
{
    pdr: body.PuntoDiRiconsegna.PDR default body.PDR default null,

    effectiveDate:
        (body.DecorrenzaSwitching default body.Decorrenza default null)
            as String default null,

    requestId: body.Intestazione.CodiceRichiesta default body.CodiceRichiesta default null,

    // Echoed from our original submission — the join key back to the
    // correlation store.
    clientRequestId: body.Intestazione.RiferimentoUtente default null,

    admissible: isAdmissible,

    reasonCode: if (isAdmissible) null else rawCode,

    reasonText:
        if (isAdmissible) null
        else (REASON_TEXT[rawCode]
              default ("The distributor rejected the request (code " ++ rawCode ++ "). "
                       ++ "Please contact customer support for details.")),

    receivedAt: now() as String {format: "yyyy-MM-dd'T'HH:mm:ss'Z'"}
}
