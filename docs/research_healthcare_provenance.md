# Healthcare Provenance Incidents: KNDB Motivation

Compiled 2026-06-30 for CIDR 2027. Every URL was fetched live.

## Top 5 Incidents

### 1. Whisper / Nabla ambient scribe hallucinations, source audio deleted (Oct 2024)

Fortune, Healthcare Brew, and ABC reported that Nabla's Whisper-based ambient scribe, at ~85 health systems and ~7M visits, hallucinated content into clinician-signed notes. Cornell/UW researchers logged hallucinations in ~1% of ~13,000 clean audio segments; a Michigan researcher hit them in 8/10 samples. Nabla's CTO confirmed source audio is deleted "for data safety reasons," so once a fabricated finding is signed, no ground truth remains.

Why it matters: canonical AI-generated-as-observed collision at the storage boundary. No epistemic tag, no upstream artifact.

Source: https://fortune.com/2024/10/26/openai-transcription-tool-whisper-hallucination-rate-ai-tools-hospitals-patients-doctors/

### 2. Sharp / Sutter / MemorialCare ambient-scribe lawsuits (2025-2026)

A San Diego class action (Nov 2025) against Sharp HealthCare alleges Abridge recorded encounters without consent, and that EHR notes contained boilerplate stating the patient had consented when no such conversation occurred. A parallel federal suit, *Washington v. Sutter Health*, N.D. Cal. No. 4:26-cv-03012 (Apr 2026), targets Sutter and MemorialCare on the same pattern.

Why it matters: the allegedly fabricated consent language is model-generated boilerplate stored with no tag distinguishing it from clinician text. Discovery-grade proof that provenance-collapsed storage carries legal exposure.

Source: https://www.hipaajournal.com/lawsuit-ai-platform-illegally-recorded-patient-clinician-conversations/

### 3. Epic Sepsis Model external validation failure, JAMA Intern Med (2021)

Wong et al., *JAMA Intern Med* 2021;181(8):1065-1070, doi:10.1001/jamainternmed.2021.2626. External validation across 38,455 Michigan Medicine hospitalizations found the vendor-shipped model missed ~two-thirds of sepsis cases and drove massive alert fatigue. The ESM score is written to the EHR every 15 minutes; downstream analytics consumed those scores as if they were observed risk signals.

Why it matters: numeric model output stored alongside vitals with no visible derived/inference marker, inherited by hundreds of hospitals before independent validation existed.

Source: https://jamanetwork.com/journals/jamainternalmedicine/fullarticle/2781307

### 4. FDA final PCCP guidance for AI-DSF (14 Feb 2025)

FDA finalized "Predetermined Change Control Plans for Artificial Intelligence-Enabled Device Software Functions." Scope broadened from ML to all AI-DSF, but the final does not require distinguishing AI-generated from measured data downstream of the device. It regulates the model, not what the model writes.

Why it matters: the top-line US AI/ML device regulator in 2025 stopped short of a storage-layer provenance mandate. KNDB argues that is exactly the gap the storage engine must fill.

Sources: https://www.fda.gov/regulatory-information/search-fda-guidance-documents/marketing-submission-recommendations-predetermined-change-control-plan-artificial-intelligence and https://www.thefdalawblog.com/2025/02/small-change-fdas-final-predetermined-change-control-plan-pccp-guidance-ditches-ml-and-adds-some-details-but-otherwise-sticks-closely-to-the-draft/

### 5. ONC HTI-1 rule, Predictive DSI source attributes (effective Jan 2025)

HTI-1 (89 FR 1192, published 9 Jan 2024; DSI criterion effective 1 Jan 2025) mandates 31 source attributes for Predictive DSIs and 13 for evidence-based DSIs. These describe the model, not the individual data element written to the chart. No requirement that a value produced by a Predictive DSI be stored with a persistent algorithm-origin flag.

Why it matters: HTI-1 is often cited as the AI-transparency answer. KNDB shows that model-level transparency plus provenance-less storage still produces observation/inference collision at query time.

Source: https://www.mintz.com/insights-center/viewpoints/2146/2024-01-08-hhs-onc-hti-1-final-rule-introduces-new-transparency

## Adjacent citations worth using

- npj Digital Medicine 2025, doi 10.1038/s41746-025-01670-7: 1.47% hallucination rate, 3.45% omission, 44% of hallucinations clinically major.
- Flatiron composite mortality endpoint validation, medRxiv 2025.08.20.25334011: documents imputing the 15th of the month for unknown death dates, an in-band value with no tag.
- MDPI *Biomedicines* 2025, "ML-Enabled Medical Devices Authorized by FDA in 2024" (168 devices, 94.6% via 510(k)).

## Confidence Check

1. **Whisper/Nabla, high.** Multiple 2024 outlets, direct CTO quote on audio deletion, Fortune article fetched.
2. **Sharp/Sutter lawsuits, medium-high.** HIPAA Journal source confirms Sutter case number and filing date. The Sharp fabricated-consent allegation is from secondary reporting, not the docket; treat as reported-alleged, not court-confirmed.
3. **Epic Sepsis Model, high.** Peer-reviewed JAMA Intern Med article, citation and DOI verified.
4. **FDA PCCP guidance, high.** FDA landing page and FDA Law Blog corroborate 14 Feb 2025 finalization and absence of downstream-provenance mandate.
5. **HTI-1 DSI, high.** FR date, attribute counts (31/13), and Jan 2025 effective date corroborated across Mintz, ONC test-method page, and AHIMA. Minor discrepancy on "9 categories vs 31 attributes" reflects category-vs-subitem accounting.

Gaps: no confirmed *JAMA*/*NEJM* retraction with "imputed" or "algorithmic" in the notice located. FHIR Provenance-resource adoption rate not found as a percentage in any 2024-2026 source; the 2025 State of FHIR survey does not break it out.
