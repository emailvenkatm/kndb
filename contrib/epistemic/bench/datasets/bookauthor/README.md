# Dataset D — Dong Book-Author (VLDB 2009)

## Provenance

  * Paper: Dong, Berti-Equille, Srivastava. "Integrating Conflicting
    Data: The Role of Source Dependence." VLDB 2009. PVLDB 2(1):550-561.
    http://www.vldb.org/pvldb/vol2/vldb09-pvldb47.pdf
  * Landing page for the data files: https://lunadong.com/fusionDataSets.htm
    (accessed 2026-07-12).
  * Files:
      * `book.zip` (411 KB) -> `book.txt` (3.3 MB, 33,971 lines)
        SHA-256: computed on fetch; see `book.zip` in source dir.
      * `book_golden.txt` (5 KB, 100 ISBN-10 gold answers)
      * `book_silver.txt` (50 KB, 1264 ISBN-13 silver answers — NOT
        used by F13; the ISBN-13 keys don't match book.txt's ISBN-10
        keys directly, so overlap is only 154 rows.)
  * License: page does not specify. VLDB 2009 paper predates the modern
    open-data licensing conventions; the page is publicly linked from
    Xin Luna Dong's personal site with no explicit terms. Redistribution
    risk assessed as low (academic-standard 17-year-old benchmark, used
    by DART / CATD / SLiMFast / dozens of follow-on papers). We do NOT
    commit book.txt itself — only book_golden.txt (5 KB, no author-list
    copyright concern) is committed, and the source dir is
    .gitignore'd (see repo-level `.gitignore` for `bench/datasets/*/
    source/`). The normalized replay traces derived from book.txt ARE
    committed (they're highly derived one-per-source-per-book records
    with no substantial reuse of the original expression).

## Size

  * 895 unique bookstores (data sources).
  * 1265 unique ISBNs (of which 100 have gold author lists in
    book_golden.txt).
  * 33,971 total (source, isbn, title, author-list) assertions.
  * After restricting to gold-covered ISBNs: 2861-2922 assertions
    across 100 ISBNs (varies slightly by K because the tiering-driven
    trace can drop blank-author rows).

## Ground truth

`book_golden.txt` maps ISBN-10 -> canonical author list as printed on
the book's cover. Assembled by Dong et al. from AbeBooks metadata plus
cover-image inspection (per VLDB'09 Sec 6.5).

Example: `9780073516677  o'leary, timothy j.;  o'leary, linda i.;`

## Correctness metric

**Precision** — fraction of the 100 gold ISBNs whose survivor's author
list matches the gold under a loose bibliographic normalization
(lowercase + collapse whitespace + strip punctuation + handle
`andapos;`; per-author token-bag containment). This is looser than
Dong's own 2-gram Jaccard from VLDB'09 Sec 6.5 but stricter than
substring match. Implementation: `_bookauthor_match` in
`bench/driver/replay_dataset.py`.

The same measure is reported as `AA` (attempt-accuracy) for consistency
with the other Stage-3 datasets, since every gold ISBN is contested by
value.

## Source-reliability metric (the F13 core issue)

The rule from F13 spec: the source-to-kind mapping MUST be computable
from documented, independent metadata that exists BEFORE the conflict
resolution. If the mapping requires the answer, the experiment is
invalid.

**Rejected proxy**: Dong Table 7's per-source `Accu` numbers (Caiman
0.55, MildredsBooks 0.88, ...). Those are the OUTPUT of Dong's SIM
truth-discovery algorithm. Using them as ep_confidence for KNDB is
using one truth-discovery algorithm's output as the prior for a
different one — that IS peeking at the answer, through a proxy.

**Adopted proxy**: two structural properties of each source, both
computable in one pass over `book.txt` without reading
`book_golden.txt`:

  1. `n_listings(src)` — how many (isbn, author) rows the source
     provides across the full corpus. Documented in Dong VLDB'09
     Table 7 column "#Books". Ranges 1..2403 in this corpus (p10=1,
     p50=2, p90=45).
  2. `canon_rate(src)` — fraction of the source's author fields that
     contain a comma (proxy for "Lastname, Firstname" canonical form).
     A source that ships canonical bibliographic strings is more likely
     to be a primary bibliographic feed than a scraped aggregator.
     Distribution: bimodal at 0 and 1.

Neither is a perfect proxy. On the 10 sources in Dong's Table 7,
neither n_listings nor canon_rate cleanly stratifies by Dong's SIM-Accu
(Caiman has 1156 listings and canon=0.97 but SIM-Accu=0.55; Players
Quest has canon=0.008 but SIM-Accu=0.82). The paper's claim in F13 is
NOT that these are excellent proxies — it's that they are the best
independent proxies available in the raw data, and the sensitivity
analysis over K measures how much the result depends on the tiering.

## The mapping rule (parametric in K)

Given a top-K parameter, sources are ranked by n_listings descending.

  * Tier A: sources in the top-K/2 by n_listings AND canon_rate >= 0.5
      => ep_kind = MEASURED, ep_confidence = 1.0
  * Tier B: sources in the top-K by n_listings that don't qualify for A
      => ep_kind = INFERRED, ep_confidence = 0.7
  * Tier C: all other sources
      => ep_kind = DERIVED, ep_confidence = 0.4

The 0.5 canon-rate cutoff is the midpoint of [0,1] with no ground-truth
tuning. Confidence values 1.0 / 0.7 / 0.4 are the same defaults used
elsewhere in the KNDB test suite (see `bench/schema/pg_conf.sql`).

`ep_specificity = 0` uniformly — the dataset has no natural
specificity axis (an author list is an author list). The lattice
therefore ranks Tier A > Tier B > Tier C by kind alone, breaking ties
by confidence, then falling to xmin (F8).

## Sensitivity analysis over K

Sweep K in {10, 25, 50, 100, 200}. Cell files at
`bench/results/stage3_raw/bookauthor_<system>_c<NNN>_K<NNN>.json`.

Reported per system per K per concurrency. Precision is the primary
correctness axis; goodput and throughput are secondary. See
`bench/results/summary/stage3_bookauthor.md` for the rollup.

## Consequence for KNDB's expected behaviour

Unlike the three Stage-3 datasets in F12 (all pure temporal-shape
ground truth, KNDB=0), Book-Author's ground truth is closest to
"which sources should you trust?" — an epistemic-shaped question the
lattice can, in principle, answer. Whether it actually does depends
on whether the n_listings + canon_rate proxy carries any signal.

Expected outcomes:

  * epistemic > pg_lww: if the structural proxy has ANY signal, kind
    ranking should beat picking whoever wrote last.
  * epistemic ~ pg_conf: pg_conf uses the same ep_confidence values;
    the only difference is that KNDB's lattice ranks by (kind, spec,
    conf) whereas pg_conf ranks by confidence only. Kind ranking
    should dominate on this workload because within-tier variance in
    confidence is exactly 0 (all Tier A = 1.0, etc.).
  * pg_heap: uniform garbage. Multiple live rows per slot; the scan's
    "first row wins" is a coin flip. Reported for completeness but
    should NOT be interpreted as correctness — it's an integrity
    failure that happens to sometimes return the right value.

## File paths

  * Raw source (git-ignored):
    `bench/datasets/bookauthor/source/book.txt`
    `bench/datasets/bookauthor/source/book_golden.txt`
    `bench/datasets/bookauthor/source/book_silver.txt`
    `bench/datasets/bookauthor/source/book.zip`
  * Normalized traces (per K):
    `bench/datasets/bookauthor/normalized_K{010,025,050,100,200}.jsonl`
  * Results:
    `bench/results/stage3_raw/bookauthor_<system>_c<NNN>_K<NNN>.json`
    `bench/results/summary/stage3_bookauthor.md`
