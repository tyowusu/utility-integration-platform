%dw 2.0
output application/xml encoding="UTF-8", writeDeclaration=true

/**
 * ============================================================================
 * CANONICAL → SII SWITCHING REQUEST (tracciato XML)
 * ============================================================================
 *
 * Maps the platform's canonical switching request onto the XML structure
 * exchanged with the SII.
 *
 * IMPORTANT — SPECIFICATION FIDELITY
 * ----------------------------------
 * The element names, ordering and cardinality below follow the shape of the
 * SII switching tracciato but are a REPRESENTATIVE STRUCTURE, not a verbatim
 * reproduction of the current specification. Acquirente Unico publishes the
 * authoritative technical specification ("Specifiche Tecniche — Processo di
 * Switching", and the gas-specific variant) on the SII portal, and revises it
 * periodically.
 *
 * Any real implementation must generate this mapping against the current
 * published version and validate output against the official XSD before
 * transmission. This module is written to demonstrate the mapping pattern and
 * the isolation strategy — not to substitute for the specification.
 *
 * WHY THE MAPPING IS ISOLATED HERE
 * --------------------------------
 * A tracciato revision is a routine event. Confining it to one versioned
 * module means a specification bump is a contained, testable change rather
 * than a hunt through flow logic. The module name should carry the
 * specification version once pinned to a real one.
 * ============================================================================
 */

var req = vars.switchingRequest
var sellerCode = p('sii.seller.code')

fun isoDate(d) = (d as Date) as String {format: "yyyy-MM-dd"}

---
RichiestaSwitching @(versione: p('sii.tracciato.version')) : {
    // ---- Header: who is asking, and when -----------------------------------
    Intestazione: {
        // Seller's SII operator code — issued by Acquirente Unico at
        // accreditation and environment-specific, hence externalised.
        CodiceUtente: sellerCode,
        TipoRichiesta: "SWITCH",
        DataRichiesta: isoDate(now()),

        // Our correlation id, echoed by SII on the asynchronous outcome.
        // This is what makes request and outcome re-joinable.
        RiferimentoUtente: vars.clientRequestId
    },

    // ---- Supply point ------------------------------------------------------
    PuntoDiRiconsegna: {
        PDR: req.pdr,
        // Distributor code, where the Seller already holds it. Omitted rather
        // than guessed: SII resolves the distributor from the PDR, and an
        // incorrect explicit value is rejected where an absent one is not.
        (CodiceDistributore: req.distributorCode) if (req.distributorCode != null)
    },

    // ---- Counterparty ------------------------------------------------------
    ClienteFinale: {
        TipoCliente: req.customerType,
        CodiceFiscale: upper(req.fiscalCode),
        (RagioneSociale: req.businessName) if (req.customerType == "BUSINESS"),
        (Cognome: req.lastName) if (req.customerType == "RESIDENTIAL"),
        (Nome: req.firstName) if (req.customerType == "RESIDENTIAL")
    },

    // ---- Regulated effective date -----------------------------------------
    // Already validated as the first day of a month, within the submission
    // window. See validate-switching-request.dwl.
    DecorrenzaSwitching: req.effectiveDate,

    // ---- Provenance --------------------------------------------------------
    // Retained for ARERA commercial-quality evidencing: the Seller must be
    // able to demonstrate how each request originated.
    Provenienza: {
        Canale: req.channel,
        Operatore: req.operatorId
    }
}
