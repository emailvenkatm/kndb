# Cross-Industry Provenance Failures: Research Notes for KNDB (CIDR 2027)

Motivation-section material. Real incidents outside healthcare where model
outputs, enrichment guesses, or inferred values got stored indistinguishably
from measured values, and something broke. Every URL below was fetched.

## Top-5 Incidents

### 1. Meta "Potential Reach" — modeled audience sold as measured metric
*DZ Reserve v. Meta Platforms* (N.D. Cal. 3:18-cv-04978). Plaintiffs allege
Meta's Potential Reach was inflated 200-400% because it counted duplicate
and fake accounts, then surfaced to advertisers as a sizing input at bid
time. Court records show Meta executives internally acknowledged the
inflation in 2017-2018. Ninth Circuit affirmed class cert; Supreme Court
declined to intervene; jury trial vacated October 2025, next-steps hearing
December 4, 2025. Damages sought: ~$7B.
Sources: https://www.cohenmilstein.com/case-study/dz-reserve-et-al-v-facebook/ ,
https://searchengineland.com/advertisers-sue-meta-inflating-ad-viewership-438884
KNDB relevance: a derived estimate travelled through the API as if it were
a measured count. No epistemic-kind tag forced callers to treat it as
inference. Textbook motivating example.

### 2. Zillow Offers — Zestimate output used as purchase-price input
Zillow shut down its iBuying arm November 2021 after ~$569M in inventory
write-downs and a 25% workforce cut. Root cause: algorithmic valuation was
treated as sufficient signal to bid, downstream systems never distinguished
"model prediction" from "verified comparable." Stanford GSB frames it as
the "lemons problem" — algorithmic estimates used where deeper appraisal
was required.
Source: https://www.gsb.stanford.edu/insights/flip-flop-why-zillows-algorithmic-home-buying-venture-imploded
KNDB relevance: model score consumed downstream as market price. A
`kind = inference` tag would force a policy check before the bidding
system trusts it.

### 3. Hello Digit / CFPB, August 2022 — algorithmic estimate treated as authorized withdrawal
CFPB fined Hello Digit $2.7M plus $68,145 in redress. The autosave
algorithm estimated a "safe" transfer amount; downstream banking flows
executed those estimates as authorized ACH debits, triggering ~70,000
overdraft reimbursement requests since 2017.
Source: https://www.consumerfinance.gov/about-us/newsroom/cfpb-takes-action-against-hello-digit-for-lying-to-consumers-about-its-automated-savings-algorithm/
KNDB relevance: an ML prediction of affordability was materialized into a
measured, authorized debit. Provenance did not survive the API boundary
between the algo and the ACH rails.

### 4. GA4 Blended reporting — modeled events silently mixed with observed events
Google's default GA4 "Blended" reporting identity injects modeled
conversions into the same report rows as observed events once thresholds
activate. Multiple 2024-2026 analyses document 15-70% attribution gaps and
cross-tool discrepancies: Meta reports ~26% higher conversions than
analytics tools; Google Ads over-attributes 15-20% under Enhanced
Conversions / Consent Mode V2. Ads teams cannot tell which conversions per
row were measured vs modeled.
Sources: https://easyinsights.ai/blog/why-conversions-dont-match-across-meta-google-and-ga4-and-how-to-fix-cross-platform-attribution/ ,
https://plausible.io/blog/consent-mode-ga4-modeled-data
KNDB relevance: the current, live version of the problem — production
analytics store that structurally cannot express `kind`.

### 5. Sambasivan et al. 2021 — "Data Cascades" (peer-reviewed corroboration)
CHI 2021 study of 53 AI practitioners across three continents. Documents
how early data-provenance failures compound downstream. Grounds the
premise that data-quality issues, including imputation and silent defaults,
are under-tracked and cause outsized production incidents.
ACM DOI 10.1145/3411764.3445518. Direct DOI fetch returned HTTP 403;
verified via search snippet and Shankar et al.'s 2024 follow-up
(https://arxiv.org/pdf/2209.09125).
KNDB relevance: peer-reviewed evidence that "impute-then-store without
provenance" is a systemic MLOps failure mode, not one bad team.

## Secondary Findings

- **ZoomInfo $29.55M settlement (Nov 2024, Ramos et al.)** at
  https://zoominforightofpublicitysettlement.com/ is right-of-publicity,
  NOT data accuracy. Do not cite for accuracy.
- **Apollo.io Illinois class action** (classaction.org) is consent-based,
  not accuracy. Skip.
- **CFPB guidance, adverse-action notices for AI/ML credit denials**:
  https://www.consumerfinance.gov/about-us/newsroom/cfpb-issues-guidance-on-credit-denials-by-lenders-using-artificial-intelligence/
- **dbt Labs 2024 State of Analytics Engineering**: 57% cite poor data
  quality as top issue, up from 41% in 2022. Doesn't isolate imputation.
  https://www.getdbt.com/resources/state-of-analytics-engineering-2024
- **Shankar et al. 2024** (arXiv:2403.16795) cites a real corrupted
  imputation-value bug in production.

## Confidence Check

| # | Incident | Confidence | Notes |
|---|----------|------------|-------|
| 1 | Meta Potential Reach | HIGH | Multiple court docs, active docket, live 2025 |
| 2 | Zillow Offers | HIGH | Writedown range $304M-$569M across sources; cite the range |
| 3 | Hello Digit CFPB | HIGH | Primary CFPB press release fetched |
| 4 | GA4 blended | MEDIUM-HIGH | Mechanism solid, per-advertiser dollar figures anecdotal |
| 5 | Data Cascades | HIGH existence, MEDIUM imputation-specific quote — re-verify ACM camera-ready via institutional network before submission |

## Tooling and Surprises

Live WebSearch worked. WebFetch worked for HTML/CFPB; arxiv PDF returned
binary, ACM DOI page returned 403 — flagged above.

Surprises: (a) the strongest non-healthcare case is advertising, not
finance — Meta Potential Reach is courtroom-tested. (b) Zillow is
under-cited in provenance literature but is a near-perfect KNDB story: an
untagged model output flowing into a transactional pricing decision. (c)
Two of the biggest ZoomInfo/Apollo suits are consent cases, not accuracy
cases; easy to mis-cite.
