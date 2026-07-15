# zheng_sentiment — Zheng VLDB'17 `d_sentiment` (F15)

This README is written BEFORE any run for the F15 replication of F14's
confidence-forgery result on a second, independent, authority-shaped
dataset. Mapping is pre-registered here and does NOT adapt to outcomes.

## Why this dataset (and not CytoCrowd, the primary target)

F15 first attempted CytoCrowd (arXiv:2602.06674v1, WWW '26). The paper
exists and matches the description (446 cytology images, 4 board-certified
pathologists, 6,402 gold ROIs from a >15y-experience senior expert). But:

  1. **No dataset artefact URL.** The paper points only to institutional
     home pages (hkust-gz.edu.cn, en.gzlbp.com). Data-availability section
     absent from the 8-page paper. The images are .svs whole-slide files
     that would be behind an institutional/DUA channel even if listed.
  2. **No credential tier signal.** All 4 pathologists are peer-level
     board-certified, each with >10y clinical experience. There is no
     public "senior vs junior" split among annotators — the only tiered
     party is the gold-standard rater, who we are NOT allowed to use as
     a source signal (gold-peeking).

Per the F15 pre-registered pivot rule ("If CytoCrowd's dataset artefact
is behind a login wall or requires DUA: fall back to Zheng and disclose
the fallback plainly"), we fell back to Zheng et al.'s truth-inference
benchmark.

Specifically we use the `d_sentiment` sub-dataset because it is the ONLY
one in Zheng's release that ships an independent **qualification test**
per worker — 1,700 worker responses to a disjoint set of 20 gold-labeled
items, giving us a per-worker quality signal that (a) exists BEFORE any
main-task label is seen and (b) does not peek at main-task gold.

## Provenance

* **Paper**: Yudian Zheng, Guoliang Li, Yuanbing Li, Caihua Shan, Reynold
  Cheng. "Truth Inference in Crowdsourcing: Is the Problem Solved?"
  PVLDB 10(5):541-552, 2017.
  <https://dl.acm.org/doi/10.14778/3055540.3055547>
  <https://www.vldb.org/pvldb/vol10/p541-zheng.pdf>
* **Code / dataset repo**: <https://github.com/zhydhkcws/crowd_truth_infer>
  (README says all datasets are made public for future research).
* **Datasets archive downloaded from**:
  <https://zhydhkcws.github.io/crowd_truth_inference/datasets.zip>
  Downloaded 2026-07-12; SHA-256 of the zip:
  `c68ee01613da6dd6e2405c3252b73bb1199bc263909588bf952f57fc7d84323c`.
* **License**: not explicitly stated in the archive. Zheng's paper is
  CC-BY-SA per PVLDB standard. We use the data for research replication,
  ship only our re-normalized derivative (not the raw AMT worker IDs
  beyond what Zheng published), and cite verbatim.
* **Sub-dataset**: `d_sentiment` (decision-making task, sentiment
  classification of movie-review snippets on Amazon Mechanical Turk).

Files copied verbatim into `source/`:

  * `answer.csv` — 20,000 (question_id, worker_id, answer) rows across
    1,000 questions and 85 workers, ~20 labels/question, 999/1000
    questions have >1 distinct label (contested).
  * `truth.csv` — 1,000 gold labels for the main-task questions.
  * `quali.csv` — 1,700 worker responses to a separate qualification
    test (20 gold items, ~20 answers per worker; ALL 85 workers took it).
  * `quali_truth.csv` — 20 gold labels for the qualification items (a
    disjoint set from the main-task items; verified — quali IDs 2000..2019
    do not overlap with main-task IDs 0..999).

## Size (verified from source)

| Statistic                                    | Value  |
|----------------------------------------------|--------|
| Workers (annotators)                         |     85 |
| Main-task items (questions)                  |  1,000 |
| Main-task labels                             | 20,000 |
| Contested slots (>=2 distinct labels)        |    999 |
| Qualification-test items (disjoint from main)|     20 |
| Qualification responses                      |  1,700 |
| Workers with quali coverage / total          | 85 / 85|
| Quali accuracy range (min .. max)            | 0.30 .. 0.95 |
| Quali accuracy quartiles (25/50/75)          | 0.75/0.80/0.85 |

## Mapping rule (pre-registered)

### Independent per-worker signal

For each worker `w`, compute `quali_acc(w)` = (# quali items where `w`'s
answer equals `quali_truth`) / (# quali items `w` responded to).

This signal is:

  * INDEPENDENT of the main-task ground truth (`truth.csv`), which is
    the F15 rule's non-negotiable "no gold peeking" constraint. The
    qualification items are a disjoint set of question IDs (2000..2019
    vs main-task 0..999).
  * COMPUTABLE before any main-task label is written or arbitrated. It
    exists in the dataset as ground-in-place metadata.
  * DIRECTLY analogous to CytoCrowd's board-certification tier that the
    primary target lacked publicly — a worker's independently measured
    skill level.

### Tier assignment (K-parametric)

Given a sensitivity parameter `K` (the number of top-quali workers who
get the highest tier), sort workers by `quali_acc` desc (stable tie-break
on worker_id):

  * **Tier A (top K/3 by quali_acc)** — MEASURED, ep_confidence uniform [0.5, 0.9]
  * **Tier B (middle third: rank K/3 .. 2K/3 within top-K)** — INFERRED, ep_confidence uniform [0.4, 0.7]
  * **Tier C (bottom third of top-K + all workers outside top-K)** — DERIVED, ep_confidence uniform [0.2, 0.5]

K sweep: **K ∈ {12, 24, 45, 66, 85}**. Chosen to match the dataset's
85-worker population — 85 is the "all workers get a tier better than C"
extreme; 12 puts about a seventh of the workforce in each of A/B and the
rest in C. Rationale for using thirds-within-top-K (not halves like
F14's Book-Author): d_sentiment has one signal (quali_acc), not two
(n_listings + canon_rate); thirds are the natural three-way split of a
single-signal ranking without inventing a second axis.

### Confidence-range motivation (matches F14)

Same ranges as F14 Book-Author so we test the same kind-vs-confidence
disagreement mechanism, not a re-tuned one. Adversarial writes will
use uniform [0.95, 1.0] just like F14.

### Trace construction

Each of the 20,000 (question, worker, answer) rows becomes ONE write:

  * `entity_id = stable_entity_id("zheng_sentiment::" + question_id)`
  * `attribute = "sentiment"`
  * `value = "pos"` if answer==1 else "neg" (Zheng codes 0/1 for the
    binary sentiment decision task)
  * `ep_kind, ep_confidence` from the tier of the worker
  * `ep_specificity = 0` (uniform, no source specificity signal exists)
  * `valid_time_lower_epoch` = base_epoch + row_index * 60 (arrival
    order preserved from the raw file line order; every write within
    the same epoch would produce KNDB tie-break issues)
  * `sources = ["zheng_worker::" + worker_id]` for INFERRED/DERIVED,
    NULL for MEASURED (matches KNDB R3 registration model)
  * `ground_truth_survivor = "pos" if truth==1 else "neg"` (from
    `truth.csv`; the correctness scorer uses this and NOTHING else
    peeks at it before)

### Adversarial injection (F14-shape)

For each contested main-task slot (999 of 1000), inject `N` adversarial
writes with:

  * `ep_kind = INFERRED`
  * `ep_confidence` uniform [0.95, 1.0] (deterministic RNG, seed
    20260715 XOR record_index)
  * `value` = the wrong label ("pos" if gold=="neg" else "neg") — i.e.,
    flip the sentiment. Alternative "scrambled" strategy is meaningless
    here because there are only 2 classes; the wrong answer is unique.
  * `sources = ["adversarial_agent_" + i]`
  * Insertion position: random within the trace (seed 20260715), so
    adversarial can arrive before/mid/after the honest writers.

`N` sweep: **N ∈ {1, 3, 5, 10}** (matches F14 exactly).

### Independence self-audit

Explicitly:

  * `quali_acc(w)` is computed from `quali.csv` and `quali_truth.csv`
    ONLY. Never touches `answer.csv` or `truth.csv`.
  * `tier(w) := K, quali_acc(w)` — no gold on main task involved.
  * Adversarial value ("flip gold") DOES consult `truth.csv`. That is
    by design — the F14 threat model is a hostile writer who knows
    what to attack. Real threat actors have gold. Only the *tier
    mapping* must be gold-independent, not the *adversarial payload*.
    (F14 followed the same rule for its "scrambled" wrong values.)

### Correctness scorer

Same as bookauthor: per-slot survivor read from `WHERE upper(sys_time) =
'infinity'`, matched to gold via exact string equality (labels are
2-class categorical, no bibliographic normalization needed).

Metric: `Precision` = (# gold slots with a matching live survivor) /
(# gold slots). Same convention as F14 Book-Author.

## Sensitivity threshold values used in this run

  * `K` in the tier assignment: {12, 24, 45, 66, 85}
  * `N` adversarial per gold slot: {1, 3, 5, 10}
  * Concurrency: {c=1, c=8}. c=32 skipped (F15 rule: bound wall clock).
  * `adv_seed`: 20260715 (fixed; distinct from F14's 20260714 so the
    two experiments don't accidentally share a random draw).
  * Isolation: SERIALIZABLE for KNDB, per-system defaults for the rest.

## Predictions (recorded before Task 4 ran)

  * **KNDB epistemic**: kind axis picks MEASURED (Tier-A worker's
    honest label) over INFERRED (adversarial). Precision stays near
    the baseline (no-adversarial) level across all N.
  * **pg_conf**: adversarial conf 0.95-1.0 beats honest MEASURED conf
    0.5-0.9. Precision collapses toward 0 as N grows.
  * **pg_lww**: last-writer-wins; adversarial wins iff it's inserted
    last for that slot. With ~20 honest writes and N adversarial,
    P(adversarial is last) ~= N/(N+20). Precision degrades slowly.
  * **pg_mv**: majority vote; adversarial only wins when N is close to
    the honest vote count. With 20 honest votes distributed across two
    labels (roughly majority for gold when workers are >0.5 accurate),
    adversarial N=1,3,5 rarely swings; N=10 competes with an ~11 vs 10
    honest split.
  * **pg_llm**: mock LLM's kind-aware pick (per F14 pattern) tracks
    KNDB scaled by Bernoulli(P_correct=0.925). At N=5 c=1.
  * **pg_heap**: INTEGRITY FAIL always (no arbitration).
  * **pg_trigger**: same lattice as KNDB via plpgsql -> tracks KNDB
    within tie-break noise.

If any prediction is falsified on the empirical run, the F15 report
will state so plainly and NOT edit the prediction post-hoc.
