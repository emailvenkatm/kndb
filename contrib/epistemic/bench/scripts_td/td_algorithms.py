"""
Truth-discovery baselines for F16 (categorical / single-label tasks only).

Implements four published algorithms from scratch:

  1. TruthFinder     — Yin, Han, Yu. "Truth Discovery with Multiple
                        Conflicting Information Providers on the Web."
                        KDD 2007. Iterative trust <-> confidence.
  2. CRH             — Li et al. "Resolving Conflicts in Heterogeneous
                        Data by Truth Discovery and Source Reliability
                        Estimation." SIGMOD 2014. Weighted-loss opt.
  3. CATD            — Li et al. "A Confidence-Aware Approach for Truth
                        Discovery on Long-Tail Data." VLDB 2015.
                        Chi-squared confidence-bounded weights.
  4. ACCU            — Dong, Berti-Equille, Srivastava. "Integrating
                        Conflicting Data: The Role of Source Dependence."
                        VLDB 2009 / IEEE TKDE 2010. Bayesian
                        source-accuracy + n-domain claim priors. We
                        implement the base ACCU variant (no
                        copy-detection step).

Each algorithm is:
  - Fresh reimplementation from the published equations, not vendored.
  - Deterministic given the same input (uses `random.Random(seed)` for
    tie-breaks; no numpy RNG globals).
  - Categorical / single-label only. F14/F15 workloads are:
      * Book-Author: single-value author-string per ISBN.
      * Zheng d_sentiment: single binary label per question.
    Continuous-value support is out of scope; we're baselining against
    the F14/F15 attack, which is categorical.

Input format (common across algorithms):

    claims: List[Tuple[item_id, source_id, value_str]]

Output:

    predicted_truth: Dict[item_id, value_str]
    source_weight:   Dict[source_id, float]  (interpretation varies)

The predictions are then handed to the same `score_correctness` scorer
KNDB and pg_conf use, via `run_td_offline.py`.

References (verified 2026-07-12):
  * TruthFinder KDD07: https://dl.acm.org/doi/10.1145/1281192.1281309
    (arxiv-free PDF at
    http://web.cs.ucla.edu/~yzsun/classes/2014Spring_CS7280/Papers/Trust/kdd07_xyin.pdf)
  * CRH SIGMOD14: https://dl.acm.org/doi/10.1145/2588555.2610509
  * CATD VLDB15: https://dl.acm.org/doi/10.14778/2735479.2735486
  * ACCU VLDB09/TKDE10: Dong, Berti-Equille, Srivastava, PVLDB 2(1):550-561
"""

from __future__ import annotations

import collections
import math
import random
from typing import Any, Dict, List, Optional, Sequence, Tuple

try:
    from scipy.stats import chi2  # type: ignore
    _HAVE_SCIPY = True
except Exception:  # pragma: no cover -- scipy is required for CATD
    _HAVE_SCIPY = False


Claim = Tuple[Any, Any, Any]  # (item_id, source_id, value)


# --------------------------------------------------------------------
# Common utilities.
# --------------------------------------------------------------------

def _group_by_item(claims: Sequence[Claim]
                   ) -> Dict[Any, List[Tuple[Any, Any]]]:
    """items -> [(source, value), ...]"""
    out: Dict[Any, List[Tuple[Any, Any]]] = collections.defaultdict(list)
    for it, src, val in claims:
        out[it].append((src, val))
    return out


def _group_by_source(claims: Sequence[Claim]
                     ) -> Dict[Any, List[Tuple[Any, Any]]]:
    """sources -> [(item, value), ...]"""
    out: Dict[Any, List[Tuple[Any, Any]]] = collections.defaultdict(list)
    for it, src, val in claims:
        out[src].append((it, val))
    return out


def _majority_vote(item_to_sv: Dict[Any, List[Tuple[Any, Any]]],
                   seed: int = 0) -> Dict[Any, Any]:
    """Majority vote with deterministic random tie-break."""
    rng = random.Random(seed)
    truth: Dict[Any, Any] = {}
    for it in sorted(item_to_sv.keys(), key=str):
        counts: Dict[Any, int] = collections.Counter()
        for _s, v in item_to_sv[it]:
            counts[v] += 1
        if not counts:
            continue
        top = max(counts.values())
        winners = sorted([v for v, c in counts.items() if c == top], key=str)
        truth[it] = winners[0] if len(winners) == 1 else rng.choice(winners)
    return truth


# --------------------------------------------------------------------
# TruthFinder (Yin/Han/Yu KDD 2007).
#
# Setup:
#   sigma(f)  = -sum_{w in W(f)} ln(1 - t(w))   ... eq (3)
#   sigma*(f) = sigma(f) + rho * sum_{f' != f, o(f')==o(f)}
#                   sigma(f') * imp(f' -> f)     ... eq (6)
#   s(f)      = 1 / (1 + exp(-gamma * sigma*(f))) ... eq (7)
#   t(w)      = mean_{f in F(w)} s(f)              ... eq (8)
#
# For F14/F15 (small implication signal — Book-Author strings are
# compared verbatim, Zheng labels are binary) we use the identity
# implication: imp(f,f)=1, imp(f',f)=0 for f'!=f. This is the
# "simple" TruthFinder configuration Yin/Han/Yu used for numeric
# and categorical domains where fact similarity is not defined.
# It is a HONEST TruthFinder configuration.
# --------------------------------------------------------------------

def truthfinder(claims: Sequence[Claim],
                dampening_factor: float = 0.3,
                influence_related: float = 0.5,
                initial_trust: float = 0.9,
                max_iter: int = 100,
                epsilon: float = 1e-6,
                seed: int = 0
                ) -> Tuple[Dict[Any, Any], Dict[Any, float]]:
    """
    Categorical TruthFinder. Returns (predicted_truth, source_trust).

    Uses identity implication (imp(f',f)=0 for f'!=f). The eq (6)
    off-diagonal term vanishes, but eq (5), (7), (8) are exactly
    Yin/Han/Yu.
    """
    item_to_sv = _group_by_item(claims)
    src_to_iv = _group_by_source(claims)
    sources = sorted(src_to_iv.keys(), key=str)

    # Clamp initial trust to avoid ln(0) blow-up on the very first iter.
    trust: Dict[Any, float] = {s: initial_trust for s in sources}
    prev_trust_vec = [trust[s] for s in sources]

    # Precompute per-item unique fact list.
    item_facts: Dict[Any, List[Any]] = {
        it: sorted({v for _s, v in svs}, key=str)
        for it, svs in item_to_sv.items()
    }
    # Precompute per-fact source list.
    item_fact_sources: Dict[Tuple[Any, Any], List[Any]] = {}
    for it, svs in item_to_sv.items():
        for s, v in svs:
            item_fact_sources.setdefault((it, v), []).append(s)

    for iteration in range(max_iter):
        # Step 1: fact confidence sigma(f) from source trust.
        sigma: Dict[Tuple[Any, Any], float] = {}
        for it, facts in item_facts.items():
            for f in facts:
                s_sum = 0.0
                for s in item_fact_sources[(it, f)]:
                    # -ln(1 - t(w)); clamp trust to [eps, 1-eps]
                    t = max(1e-6, min(1 - 1e-6, trust[s]))
                    s_sum += -math.log(1.0 - t)
                sigma[(it, f)] = s_sum

        # Step 2: fact confidence s(f) via sigmoid.
        s_conf: Dict[Tuple[Any, Any], float] = {
            k: 1.0 / (1.0 + math.exp(-dampening_factor * v))
            for k, v in sigma.items()
        }

        # Step 3: source trust from mean s(f) over sources' facts.
        new_trust: Dict[Any, float] = {}
        for s in sources:
            confs = [s_conf[(it, v)] for it, v in src_to_iv[s]]
            new_trust[s] = sum(confs) / len(confs) if confs else initial_trust

        trust = new_trust
        cur_vec = [trust[s] for s in sources]
        delta = math.sqrt(sum((a - b) ** 2
                              for a, b in zip(cur_vec, prev_trust_vec)))
        prev_trust_vec = cur_vec
        if delta < epsilon:
            break

    # Predict truth: per item, pick fact with max s_conf; tie -> deterministic.
    rng = random.Random(seed)
    predicted: Dict[Any, Any] = {}
    for it, facts in item_facts.items():
        confs = [(s_conf[(it, f)], f) for f in facts]
        best = max(c for c, _ in confs)
        winners = sorted([f for c, f in confs if c == best], key=str)
        predicted[it] = winners[0] if len(winners) == 1 else rng.choice(winners)

    return predicted, trust


# --------------------------------------------------------------------
# CRH (Li et al. SIGMOD 2014).
#
# For categorical labels with 0/1 loss:
#   weight(s) = -ln( d(s) / d_max )         (eq. 10, sec. 3.1)
# where d(s) = sum over s's items of 1[truth(item)!=claim(s,item)].
#
# Truth pick: argmax over labels of sum of weights of sources voting
# for that label. Init by majority vote.
# --------------------------------------------------------------------

def crh(claims: Sequence[Claim],
        max_iter: int = 100,
        epsilon: float = 1e-6,
        seed: int = 0
        ) -> Tuple[Dict[Any, Any], Dict[Any, float]]:
    """
    Categorical CRH with 0/1 loss (per SIGMOD14 sec 4.2, table 2).
    """
    item_to_sv = _group_by_item(claims)
    src_to_iv = _group_by_source(claims)
    sources = sorted(src_to_iv.keys(), key=str)

    truth = _majority_vote(item_to_sv, seed=seed)
    prev_weight = {s: 1.0 for s in sources}
    weight = dict(prev_weight)

    for it in range(max_iter):
        # Step: recompute source weights.
        raw: Dict[Any, float] = {}
        for s in sources:
            d = 0.0
            for item, v in src_to_iv[s]:
                if truth.get(item) != v:
                    d += 1.0
            raw[s] = d
        d_max = max(raw.values()) if raw else 1.0
        if d_max <= 0:
            # All sources agree with current truth; keep uniform weights
            weight = {s: 1.0 for s in sources}
        else:
            for s in sources:
                # Small epsilon so ln doesn't blow up when a source is
                # perfectly correct against the current truth estimate.
                ratio = (raw[s] + 1e-9) / (d_max + 1e-9)
                weight[s] = -math.log(ratio + 1e-9) + 1e-9

        # Step: recompute truth via weighted majority.
        rng = random.Random(seed + it)
        new_truth: Dict[Any, Any] = {}
        for item, svs in item_to_sv.items():
            score: Dict[Any, float] = collections.defaultdict(float)
            for s, v in svs:
                score[v] += weight[s]
            if not score:
                continue
            top = max(score.values())
            winners = sorted([v for v, sc in score.items() if sc == top],
                             key=str)
            new_truth[item] = winners[0] if len(winners) == 1 else rng.choice(winners)

        # Convergence: L1 delta on weights.
        delta = sum(abs(weight[s] - prev_weight[s]) for s in sources)
        prev_weight = dict(weight)
        truth = new_truth
        if delta < epsilon:
            break

    return truth, weight


# --------------------------------------------------------------------
# CATD (Li et al. VLDB 2015).
#
# Categorical variant (paper Sec 4, "For categorical data"):
#   dif(s) = sum_i 1[truth(i) != claim(s,i)]     (0/1 loss)
#   n_s    = # items s labeled
#   Use chi-square upper confidence bound:
#     if n_s <= 30:  chi = chi2.isf(alpha/2, n_s)   (Table 1 in paper)
#     else:         chi = 0.5 * (z + sqrt(2*n_s - 1))^2  (normal approx)
#   weight(s) = chi / (dif(s) + tiny)
#   normalize weights so sum == 1.
#
# Truth pick: weighted majority. Init by majority vote.
# --------------------------------------------------------------------

def catd(claims: Sequence[Claim],
         alpha: float = 0.05,
         max_iter: int = 100,
         epsilon: float = 1e-6,
         seed: int = 0
         ) -> Tuple[Dict[Any, Any], Dict[Any, float]]:
    """
    Categorical CATD. `alpha` is the confidence level (0.05 -> 95%).
    Follows Li VLDB'15 sec 4 verbatim.
    """
    if not _HAVE_SCIPY:
        raise RuntimeError("CATD requires scipy for chi-square inv-cdf")

    item_to_sv = _group_by_item(claims)
    src_to_iv = _group_by_source(claims)
    sources = sorted(src_to_iv.keys(), key=str)

    truth = _majority_vote(item_to_sv, seed=seed)
    z = float(chi2.ppf(1 - alpha / 2, df=1) ** 0.5)  # normal quantile
    # NB: scipy has norm.isf too; we just need z_{1-alpha/2} for the
    # >30 case. z_{0.975} = 1.9600.
    from scipy.stats import norm as _norm  # type: ignore
    z = float(_norm.isf(alpha / 2))

    prev_weight = {s: 1.0 for s in sources}
    weight = dict(prev_weight)

    for it in range(max_iter):
        # Source chi-square weights.
        raw: Dict[Any, float] = {}
        for s in sources:
            n_s = len(src_to_iv[s])
            if n_s <= 0:
                raw[s] = 0.0; continue
            if n_s <= 30:
                chi = float(chi2.isf(alpha / 2, df=n_s))
            else:
                chi = 0.5 * (z + math.sqrt(2 * n_s - 1)) ** 2
            dif = 0.0
            for item, v in src_to_iv[s]:
                if truth.get(item) != v:
                    dif += 1.0
            raw[s] = chi / (dif + 1e-9)

        # Normalise to sum 1 (Li VLDB15 sec 4, "normalized weights").
        tot = sum(raw.values())
        if tot > 0:
            weight = {s: raw[s] / tot for s in sources}
        else:
            weight = {s: 1.0 / len(sources) for s in sources}

        # Weighted majority to update truth.
        rng = random.Random(seed + it)
        new_truth: Dict[Any, Any] = {}
        for item, svs in item_to_sv.items():
            score: Dict[Any, float] = collections.defaultdict(float)
            for s, v in svs:
                score[v] += weight[s]
            if not score:
                continue
            top = max(score.values())
            winners = sorted([v for v, sc in score.items() if sc == top],
                             key=str)
            new_truth[item] = winners[0] if len(winners) == 1 else rng.choice(winners)

        delta = sum(abs(weight[s] - prev_weight[s]) for s in sources)
        prev_weight = dict(weight)
        truth = new_truth
        if delta < epsilon:
            break

    return truth, weight


# --------------------------------------------------------------------
# ACCU (Dong, Berti-Equille, Srivastava VLDB 2009), base variant
# without copy-detection. From the paper's Sec 3 "Accu":
#
#   For each source s: accuracy A(s) in (0, 1).
#   For each item i, each candidate value v:
#     P(v | phi_i, A) proportional to
#        prod_{s claims v}  A(s) / (n - 1)     ... eq (2), each source
#                                                    that supports v
#      * prod_{s claims v'!=v}  (1 - A(s))     ... each source that
#                                                    denies v (via
#                                                    claiming v'!=v)
#     where n = number of distinct values seen for item i.
#
#   Log-domain: score(v) = sum_{s in V(v)} ln(A(s)/(n-1))
#                        + sum_{s in V(v'),v'!=v} ln(1 - A(s))
#     Pick v = argmax score(v).
#
#   A(s) update: A(s) = mean over s's items of P(claim(s,i) is truth | ...)
#
# Init: uniform A(s) = 0.8.
# Iterate to fixed point.
# --------------------------------------------------------------------

def accu(claims: Sequence[Claim],
         initial_accuracy: float = 0.8,
         n_false: Optional[int] = None,
         max_iter: int = 100,
         epsilon: float = 1e-4,
         seed: int = 0
         ) -> Tuple[Dict[Any, Any], Dict[Any, float]]:
    """
    Base ACCU (Dong VLDB'09, no copy-detection). Categorical only.

    Uses the cleaned-up formulation from Zheng et al.'s VLDB 2017 survey
    (Table 3) — the same MAP inference Dong describes but with the
    "n" parameter (number of wrong values in the domain) exposed as
    a hyperparameter:

      log P(v true | Phi_O) prop to
          sum_{s claims v} log A(s)
        + sum_{s claims v', v'!=v} log ((1 - A(s)) / n_false)

    `n_false` defaults to (global max distinct claims per item) - 1
    if not provided; that's the Zheng-survey default and matches the
    "Uniform-false-value" assumption of the paper.

    Source accuracy A(s) is initialized to `initial_accuracy` and
    iteratively refined as the mean posterior of the claimed value
    being the truth.
    """
    item_to_sv = _group_by_item(claims)
    src_to_iv = _group_by_source(claims)
    sources = sorted(src_to_iv.keys(), key=str)

    # Clamp helper
    def _clamp(x: float) -> float:
        return max(1e-6, min(1 - 1e-6, x))

    accuracy: Dict[Any, float] = {s: initial_accuracy for s in sources}
    prev_vec = [accuracy[s] for s in sources]

    # Precompute per-item value set, per-item source-value tuples.
    item_values: Dict[Any, List[Any]] = {
        it: sorted({v for _s, v in svs}, key=str)
        for it, svs in item_to_sv.items()
    }
    # Precompute per-item per-value source list.
    item_val_sources: Dict[Tuple[Any, Any], List[Any]] = {}
    for it, svs in item_to_sv.items():
        for s, v in svs:
            item_val_sources.setdefault((it, v), []).append(s)

    if n_false is None:
        max_vals = max((len(vs) for vs in item_values.values()), default=2)
        n_false = max(max_vals - 1, 1)

    for iteration in range(max_iter):
        # Compute per-item scores over candidate values, and posterior
        # P(claim(s,i) is truth | ...) for each source-observation.
        score_of_value: Dict[Tuple[Any, Any], float] = {}
        for it in item_to_sv:
            vals = item_values[it]
            for v in vals:
                s_sum = 0.0
                for s in item_val_sources[(it, v)]:
                    A = _clamp(accuracy[s])
                    # supporting term
                    s_sum += math.log(A)
                # denying sources (each source claims some other value)
                for v_other in vals:
                    if v_other == v:
                        continue
                    for s in item_val_sources[(it, v_other)]:
                        A = _clamp(accuracy[s])
                        s_sum += math.log((1.0 - A) / n_false)
                score_of_value[(it, v)] = s_sum

        # Softmax over score gives posterior probability of each value.
        posterior_val: Dict[Tuple[Any, Any], float] = {}
        for it, vals in item_values.items():
            xs = [score_of_value[(it, v)] for v in vals]
            m = max(xs) if xs else 0.0
            exps = [math.exp(x - m) for x in xs]
            Z = sum(exps)
            for v, e in zip(vals, exps):
                posterior_val[(it, v)] = e / Z if Z > 0 else (1.0 / len(vals))

        # Update source accuracy = mean posterior of the value the
        # source claimed, over the source's items.
        new_accuracy: Dict[Any, float] = {}
        for s in sources:
            ps = [posterior_val[(it, v)] for it, v in src_to_iv[s]]
            if ps:
                new_accuracy[s] = _clamp(sum(ps) / len(ps))
            else:
                new_accuracy[s] = initial_accuracy

        cur_vec = [new_accuracy[s] for s in sources]
        delta = math.sqrt(sum((a - b) ** 2
                              for a, b in zip(cur_vec, prev_vec)))
        prev_vec = cur_vec
        accuracy = new_accuracy
        if delta < epsilon:
            break

    # Final prediction: argmax posterior per item.
    rng = random.Random(seed)
    predicted: Dict[Any, Any] = {}
    for it, vals in item_values.items():
        confs = [(posterior_val[(it, v)], v) for v in vals]
        best = max(c for c, _ in confs)
        winners = sorted([v for c, v in confs if c == best], key=str)
        predicted[it] = winners[0] if len(winners) == 1 else rng.choice(winners)

    return predicted, accuracy


ALGORITHMS = {
    "truthfinder": truthfinder,
    "crh": crh,
    "catd": catd,
    "accu": accu,
}
