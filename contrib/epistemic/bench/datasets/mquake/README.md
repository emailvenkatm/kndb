# Dataset C — MQuAKE edit chains (MQuAKE-CF-3k)

## Provenance

  * Paper: Zhong, Wu, Manning. "MQuAKE: Assessing Knowledge Editing in
    Language Models via Multi-Hop Questions." EMNLP 2023.
    arXiv:2305.14795.
  * Code repo: https://github.com/princeton-nlp/MQuAKE
    Cloned at commit `fb43dadc2d8cd19d08ce81c63d957b59deb3f3cd`.
  * License: MIT (LICENSE at repo root:
    `Copyright (c) 2023 Princeton Natural Language Processing`).

## Size

  * MQuAKE-CF-3k.json: 3000 counterfactual-edit cases.
  * Total rewrites (edits) across all cases: 6015.
  * Hop distribution:
      *  1-hop cases: 1093
      *  2-hop cases: 1067
      *  3-hop cases:  572
      *  4-hop cases:  268
  * Normalized trace: 6015 slots × 2 writes = 12,030 writes,
    every slot contested by construction.

## License terms

MIT.

## Metric — Multi-Hop-Acc / UOCS

The MQuAKE paper's primary metric is **Multi-hop accuracy**: "if any
of the three multi-hop questions is correctly answered by the model,
the instance is regarded as accurate." That is a QA-time metric on
the reasoning chain, not directly a database-side metric.

For KNDB we adapt this to a DB-side surrogate we call **UOCS**
(Update Ordering Consistency Score):

    UOCS = |{cases where every rewrite's live survivor == target_new}|
           / |{cases}|

For a 1-hop case that reduces to plain per-slot accuracy on
`target_new`. For a multi-hop case, KNDB is correct only if ALL of
the case's rewrites resolved to their `target_new` value (the paper's
"consistent edit propagation" property, translated to the DB layer).

We also report the weaker per-slot metric, **Edit-Acc**:

    Edit-Acc = |{slots whose survivor == target_new}| / 6015

Edit-Acc treats each rewrite independently; UOCS demands
per-case consistency across the whole chain.

## Ground-truth definition

For each rewrite `rw` in `case["requested_rewrite"]`:

  * `arrival 0`: `rw["target_true"]["str"]` — the pre-edit value.
  * `arrival 1`: `rw["target_new"]["str"]` — the counterfactual edit
                 the benchmark expects the memory system to preserve.
  * `ground_truth_survivor = rw["target_new"]["str"]`.

## Subsetting

  * All 3000 cases used. No subsetting.
  * We use MQuAKE-CF-3k.json (not the 9k full CF file) because 3k is
    the paper's headline stratified sample and matches other papers'
    baselines. MQuAKE-T (temporal) is a different 1868-case dataset
    of real-world knowledge updates; we could add it but the CF-3k
    edits alone give 6015 write pairs which is plenty for one axis.

## Mapping to the KNDB epistemic schema

  * `ep_kind = MEASURED` for both writes. Each is a directly-asserted
    (subject, relation, value) triple from the source; no aggregation.
  * `ep_specificity = 0`, `ep_confidence = 1.0`. Same reasoning as
    Datasets A / B — the source doesn't rank arrivals.
  * `valid_time_lower = 2026-01-01Z + case_id*100 + rewrite_index*10
                        + order_i`. Deterministic, monotone within a
    case, and roomy enough that no two rewrites collide.
    `valid_time_upper = null`.
  * `sources = ["mquake_case{case}_rw{r}_{target_true|target_new}"]`.
  * Slot key namespaced by `case_id`: two cases that happen to edit
    the same (subject, relation) with different values are still two
    distinct slots per the benchmark's per-case counterfactual scope.

## Consequence for KNDB's expected behaviour

Same story as Datasets A/B: MEASURED/spec=0/conf=1.0 ties fall
through to first-committer-wins. Since arrival 0 = `target_true` and
arrival 1 = `target_new`, KNDB will preserve `target_true` — the
opposite of the benchmark's ground truth. Expected UOCS ≈ 0,
expected Edit-Acc ≈ 0.

The negative result is what makes the mechanism-attribution story
honest: the KNDB lattice's arrival-order tiebreak is deliberately
first-writer-wins for grind-resistance (F8's design tradeoff), not
because "latest wins" is universally correct. Editing benchmarks
expect the OPPOSITE convention. Both conventions are defensible; the
finding is that neither is a free lunch, and the mechanism you pick
determines which benchmark you look right on.

## File paths

  * Source repo: `bench/datasets/mquake/source/MQuAKE/`
  * MQuAKE-CF-3k:
    `bench/datasets/mquake/source/MQuAKE/datasets/MQuAKE-CF-3k.json`
  * Normalized trace: `bench/datasets/mquake/normalized.jsonl`
    (12,030 lines)
