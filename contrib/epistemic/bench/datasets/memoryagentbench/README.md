# Dataset A — MemoryAgentBench FactConsolidation

## Provenance

  * Paper: Hu, Wang, McAuley. "MemoryAgentBench: Evaluating Memory in
    LLM Agents via Incremental Multi-Turn Interactions." ICLR 2026.
    arXiv:2507.05257.
  * Code repo: https://github.com/HUST-AI-HYZ/MemoryAgentBench
    Cloned at commit `455306dcabc3842526eb83cd4e225e5d486c5c5d`
    (2026-05, latest as of 2026-07-12).
  * Data hosted on the HuggingFace Hub at
    `ai-hyz/MemoryAgentBench` split `Conflict_Resolution`.
  * License: MIT (LICENSE at repo root: `Copyright (c) 2026 Yuanzhe Hu`).

## Size

  * 8 samples in the Conflict_Resolution split, one per
    (context-length × single-hop vs multi-hop) crossing:
    `factconsolidation_{sh,mh}_{6k,32k,64k,262k}`.
  * After parsing all 8 samples' contexts into templated triples:
      * facts parsed:     37,820
      * facts skipped:    13,534  (non-templated sentences)
      * distinct slots:   23,488
      * contested slots:  14,332  (61%)

## License terms

MIT, redistributable with attribution.

## Ground-truth definition

The benchmark's Selective Forgetting task treats the LATER-numbered
fact in the corpus as the ground-truth answer. Empirically verified
on `factconsolidation_sh_6k`:

  * Q "What position does Hines Ward play?" expects `cornerback`
    (fact 36), overriding `wide receiver` (fact 3).
  * Q "What position does Rogério Ceni play?" expects `flanker`
    (fact 434), overriding `goalkeeper` (fact 6).
  * Q "What position does Lisa Leslie play?" expects `goaltender`
    (fact 169), overriding `center` (fact 14).
  * Q "What position does Robert Parish play?" expects `quarterback`
    (fact 334), overriding `center` (fact 330).

So `ground_truth_survivor` per slot = the last-appearing object at
the highest `fact_index`.

## Subsetting

  * We use every one of the 8 samples' contexts. No sample-level
    subsetting.
  * We keep only facts that match one of 25 templated regexes
    (`birth_city`, `position`, `hq_city`, `author`, `sport`,
    `founded_by`, `capital`, `citizenship`, `spouse`, etc.). That
    covers the templated conflict-resolution content that MemoryAgent
    Bench uses; free-text sentences (~2%) that don't match a template
    are dropped since they'd need per-fact NLP to align.
  * Slot key is `(hash("{sub_dataset}::{subject}"), safe(predicate))`
    to prevent collisions across the 8 sub-datasets.

## Mapping to the KNDB epistemic schema

  * `ep_kind = MEASURED` for every fact. MemoryAgentBench presents
    each fact as an equally-authoritative sentence in the corpus
    (no confidence, no source hierarchy). Any mapping to INFERRED
    would need a fabricated confidence.
  * `ep_specificity = 0` uniformly. The corpus does not encode a
    specificity ranking.
  * `ep_confidence = 1.0` uniformly. Same reasoning.
  * `valid_time_lower = 2026-01-01T00:00:00Z + fact_index minutes`.
    That preserves in-corpus order for KNDB's arrival-order-based
    tiebreak. `valid_time_upper = null` (all facts are current).
  * `sources = ["mab_{sub_dataset}_{fact_index}"]`. Traceable back
    to the exact line in the corpus.

## Consequence for KNDB's expected behaviour

Because every write is MEASURED/spec=0/conf=1.0, the epistemic
lattice cannot break the tie by any of its ranked axes. It falls
through to first-committer-wins (F8 xmin tiebreak). That means KNDB
will pick the EARLIER-arriving fact — the opposite of the benchmark's
ground truth. This is the negative-result-is-valid outcome we
predicted; the report calls it out explicitly.

## File paths

  * Source (cloned repo): `bench/datasets/memoryagentbench/source/MemoryAgentBench/`
  * Normalized trace: `bench/datasets/memoryagentbench/normalized.jsonl`
  * 37,820 lines, one write attempt per line.
