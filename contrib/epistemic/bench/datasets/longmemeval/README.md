# Dataset B — LongMemEval knowledge-update questions

## Provenance

  * Paper: Wu, Wang, Yu, Zhang, Chang, Yu. "LongMemEval: Benchmarking
    Chat Assistants on Long-Term Interactive Memory." ICLR 2025.
    arXiv:2410.10813.
  * Code repo: https://github.com/xiaowu0162/LongMemEval
    Cloned at commit `9e0b455f4ef0e2ab8f2e582289761153549043fc`
    (2026-05, latest as of 2026-07-12).
  * Data: `longmemeval_oracle.json` (15.4 MB) fetched from
    `https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/`
    on 2026-07-12. 500 samples across 6 question types; we use the
    78 samples with `question_type == "knowledge-update"`.
  * License: MIT (LICENSE at repo root: `Copyright (c) 2024 Di Wu`).

## Size

  * Full oracle file: 500 samples.
  * Knowledge-update subset: 78 samples.
  * Normalized replay trace: 78 slots × 2 writes = 156 writes,
    every one of the 78 slots is contested (by construction: each
    KU sample is one before/after pair).

## License terms

MIT, redistributable with attribution.

## Metric — Conflict Resolution Score

The LongMemEval paper does NOT define a bespoke "Conflict Resolution
Score." Its unified evaluation uses gpt-4o-2024-08-06 as an LLM judge
with per-type exact-match / semantic-match accuracy. For the
knowledge-update subset, the reported metric is plain
question-answering accuracy over the 78 samples. Verified via
https://arxiv.org/html/2410.10813v2 evaluation section.

We adopt that convention and call our metric **KU-Acc**:

    KU-Acc = |{slots whose survivor value equals answer}| / 78

The "CRS" naming in the task prompt aliases to KU-Acc since the paper
does not use a formal CRS acronym.

## Ground-truth definition

For each KU sample, `answer` is the up-to-date value the user last
told the assistant about; it always appears in the later of the two
answer sessions (`haystack_dates[1]` > `haystack_dates[0]`).
Verified by inspecting sample `6a1eabeb`: session 0 (2023-05-25) says
"personal best 27:12", session 1 (2023-05-27) says "personal best
25:50", `answer = "25 minutes and 50 seconds (or 25:50)"`.

So `ground_truth_survivor = sample["answer"]`.

## Subsetting

  * Full 78-sample knowledge-update subset. No further sampling.
  * We use only the 2 answer sessions per sample (the ones that
    contain the fact and its update). The remaining ~50 filler
    sessions in the sample's history are not conflict-relevant and
    aren't part of the replay trace.

## Mapping to the KNDB epistemic schema

  * `ep_kind = MEASURED` for both writes. The user reported the value
    in a chat turn — a direct observation, no aggregation, no guess.
  * `ep_specificity = 0`. Same across both writes; no ranking cue.
  * `ep_confidence = 1.0`. The chat statement is asserted, not hedged.
  * `valid_time_lower = epoch(haystack_dates[i])`. Preserves the
    real-world 2-day gap between the two sessions (matters for KNDB's
    xmin tiebreak because the writes are inserted in that time order).
    `valid_time_upper = null`.
  * `sources = ["lme_{qid}_sess{0|1}"]`.
  * The earlier write's value is a synthetic placeholder
    `__before__::{question_id}` — we do NOT attempt to NLP-parse the
    old value out of the free-text conversation. The role of the
    earlier write is only to make the slot contested; its content is
    intentionally distinct from `ground_truth_survivor` so a system
    that survives the earlier one is provably wrong.

## Consequence for KNDB's expected behaviour

Two MEASURED / spec=0 / conf=1.0 writes → same tie fall-through as
Dataset A. KNDB picks the earlier (synthetic-placeholder) value.
Expected KU-Acc ≈ 0. Explicitly reported as a negative result.

## File paths

  * Source repo: `bench/datasets/longmemeval/source/LongMemEval/`
  * Oracle data:
    `bench/datasets/longmemeval/source/longmemeval_oracle.json`
  * Normalized trace:
    `bench/datasets/longmemeval/normalized.jsonl` (156 lines)
