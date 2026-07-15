#!/usr/bin/env python3
"""
Stage 3 / Task 3b — dataset normalizers.

Reads each source dataset in place and emits a common JSONL replay trace
at bench/datasets/<name>/normalized.jsonl. One line per write attempt:

  {
    "entity_id": <int>,
    "attribute": "<str>",         # slot key (subject / relation-tagged)
    "value": "<str>",
    "ep_kind": "MEASURED|INFERRED|DERIVED",
    "ep_specificity": <0-255>,
    "ep_confidence": <float in [0,1]>,
    "valid_time_lower_epoch": <int>,
    "valid_time_upper_epoch": <int or null>,
    "sources": [<str>, ...],
    "ground_truth_survivor": "<str or null>",
    "dataset_metadata": {...}
  }

Also emits bench/datasets/<name>/README.md with provenance, size,
license, mapping rationale, and ground-truth definition.

Mapping decisions (documented in each per-dataset README too):

  * All source datasets are conflict-resolution benchmarks with an
    UNAMBIGUOUS ground-truth winner (the LATER-arriving fact for
    LongMemEval and MemoryAgentBench; the target_new for MQuAKE).
    In KNDB lattice terms this is closest to a "MEASURED,
    confidence=1.0" write with monotonically-increasing valid_time,
    because in each case the intent is "this new observation
    supersedes the old one." Mapping any of them to INFERRED with a
    tuned confidence would let KNDB's kind rank do most of the work
    for free and hide the mechanism's contribution behind the
    workload's own confidence choices.

  * We DELIBERATELY use MEASURED for every write. This tests whether
    KNDB's lattice can still pick the right survivor when kind + spec
    + conf all tie: the only distinguishing feature between the two
    conflicting rows is arrival order, which is what
    first-committer-wins (KNDB F8) handles.
    ---
    On this workload KNDB's expected behaviour is the EARLIER writer
    wins, which is the WRONG answer per the benchmark's ground truth.
    We report that gap honestly — this is exactly the "negative result
    that's valid" clause of the F1..F12 rules. If the mechanism the
    lattice gives us doesn't match the benchmark, we say so.

  * To let the mechanism actually differentiate itself we ALSO emit a
    second trace flavour ("_lww_wins") where later writes bump
    specificity by 1 each time; that makes KNDB agree with LWW on
    later-wins and pushes the differentiation to what KNDB does with
    ties that aren't strictly ordered.

  * ep_confidence: 1.0 for MEASURED writes across the board. Sources:
    the dataset's identifier for the intent (session ID / case ID /
    fact index).

  * entity_id / attribute: hashed into a stable int / str pair per
    slot. `entity_id = hash(subject) mod 2^30`, `attribute = predicate`
    truncated to 32 chars. Collisions extremely unlikely at these
    dataset sizes (<= 5k slots).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, Iterable, List, Optional, Tuple


# --------------------------------------------------------------------
# Common helpers.
# --------------------------------------------------------------------

def stable_entity_id(subject: str) -> int:
    """
    Deterministic 30-bit int from an arbitrary subject string.
    30 bits so entity_id * ATTRS_PER_ENTITY (=32) fits well inside a
    signed 32-bit int without touching the sign bit; matches the
    YCSB layout in bench/driver/ycsb.py.
    """
    h = hashlib.blake2b(subject.encode("utf-8"), digest_size=8).digest()
    return int.from_bytes(h[:4], "big") & 0x3FFFFFFF


def safe_attribute(predicate: str) -> str:
    """
    Squash a predicate string into an attribute-key format the fact
    tables can hold (text, but we also want it readable in query logs).
    Keep letters/digits/underscore, replace others with '_', trim to 40.
    """
    s = re.sub(r"[^A-Za-z0-9_]", "_", predicate)
    s = re.sub(r"_+", "_", s).strip("_")
    return s[:40] if s else "attr"


def epoch_of(iso_or_null: Optional[str]) -> Optional[int]:
    if not iso_or_null:
        return None
    try:
        # Best-effort ISO / common formats.
        for fmt in (
            "%Y-%m-%d %H:%M:%S", "%Y-%m-%d", "%Y/%m/%d (%a) %H:%M",
            "%Y-%m-%dT%H:%M:%S", "%Y/%m/%d %H:%M",
        ):
            try:
                dt = datetime.strptime(iso_or_null, fmt)
                dt = dt.replace(tzinfo=timezone.utc)
                return int(dt.timestamp())
            except ValueError:
                continue
    except Exception:  # noqa: BLE001
        return None
    return None


def emit(fh, rec: Dict[str, Any]) -> None:
    fh.write(json.dumps(rec, sort_keys=True, ensure_ascii=False) + "\n")


# --------------------------------------------------------------------
# Dataset A: MemoryAgentBench FactConsolidation.
# --------------------------------------------------------------------

# Each "fact" in the corpus is a natural-language sentence. We parse
# the templated ones into (subject, predicate, object) triples via a
# regex table. Only the templates that produce clean triples are
# included; free-text sentences that don't match any template are
# skipped (about ~2% of the list on inspection).

MAB_TEMPLATES: List[Tuple[re.Pattern, str, int, int]] = [
    # (regex, predicate_name, subject_group, object_group)
    (re.compile(r"^(.+?) was born in the city of (.+?)\.$"),
     "birth_city", 1, 2),
    (re.compile(r"^(.+?) died in the city of (.+?)\.$"),
     "death_city", 1, 2),
    (re.compile(r"^(.+?) plays the position of (.+?)\.$"),
     "position", 1, 2),
    (re.compile(r"^(.+?) is located in the continent of (.+?)\.$"),
     "continent", 1, 2),
    (re.compile(r"^(.+?) worked in the city of (.+?)\.$"),
     "work_city", 1, 2),
    (re.compile(r"^The director of (.+?) is (.+?)\.$"),
     "director", 1, 2),
    (re.compile(r"^(.+?) is married to (.+?)\.$"),
     "spouse", 1, 2),
    (re.compile(r"^The headquarters of (.+?) is located in the city of (.+?)\.$"),
     "hq_city", 1, 2),
    (re.compile(r"^The author of (.+?) is (.+?)\.$"),
     "author", 1, 2),
    (re.compile(r"^The chief executive officer of (.+?) is (.+?)\.$"),
     "ceo", 1, 2),
    (re.compile(r"^The univeristy where (.+?) was educated is (.+?)\.$"),
     "alma_mater", 1, 2),
    (re.compile(r"^(.+?) was founded by (.+?)\.$"),
     "founded_by", 1, 2),
    (re.compile(r"^(.+?) is associated with the sport of (.+?)\.$"),
     "sport", 1, 2),
    (re.compile(r"^The capital of (.+?) is (.+?)\.$"),
     "capital", 1, 2),
    (re.compile(r"^(.+?) is a citizen of (.+?)\.$"),
     "citizenship", 1, 2),
    (re.compile(r"^Church of Scotland was founded by (.+?)\.$"),
     "cos_founder", 0, 1),  # rare, unlikely to help
    (re.compile(r"^(.+?) speaks the language of (.+?)\.$"),
     "language", 1, 2),
    (re.compile(r"^The chairperson of (.+?) is (.+?)\.$"),
     "chairperson", 1, 2),
    (re.compile(r"^(.+?) was created in the country of (.+?)\.$"),
     "created_in", 1, 2),
    (re.compile(r"^(.+?) is famous for (.+?)\.$"),
     "famous_for", 1, 2),
    (re.compile(r"^(.+?) is employed by (.+?)\.$"),
     "employer", 1, 2),
    (re.compile(r"^The official language of (.+?) is (.+?)\.$"),
     "official_language", 1, 2),
    (re.compile(r"^The name of the current head of the (.+?) government is (.+?)\.$"),
     "head_of_gov", 1, 2),
    (re.compile(r"^(.+?) was performed by (.+?)\.$"),
     "performer", 1, 2),
    (re.compile(r"^(.+?) is a language spoken by (.+?)\.$"),
     "language_of", 1, 2),
]


def _parse_mab_fact(line: str) -> Optional[Tuple[str, str, str]]:
    for pat, pred, s_grp, o_grp in MAB_TEMPLATES:
        m = pat.match(line)
        if m:
            return (m.group(s_grp), pred, m.group(o_grp))
    return None


def normalize_mab(source_root: str, out_path: str,
                  dataset_metadata: Dict[str, Any]) -> Dict[str, Any]:
    """
    Load Conflict_Resolution split from the local HF cache (we prefetched
    earlier), or re-fetch via the datasets library. Parse each sample's
    context into templated triples, replay them into the KNDB schema.

    Ground truth: for a slot with 2+ arrivals, the LAST-arriving object
    is the ground_truth_survivor (per MemoryAgentBench Selective
    Forgetting semantics).
    """
    from datasets import load_dataset  # local import: keeps CLI light

    ds = load_dataset("ai-hyz/MemoryAgentBench", split="Conflict_Resolution")

    stats = {
        "n_samples": 0,
        "n_facts_parsed": 0,
        "n_facts_skipped": 0,
        "n_slots": 0,
        "n_contested_slots": 0,
        "sources_used": [],
    }

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    fh = open(out_path, "w")
    try:
        # Slot ordering: (sample_source, subject, predicate) -> list of
        # (fact_index, object). Because entity_id is hashed globally, we
        # namespace by sample source so slot collisions across the
        # 8 sub-datasets don't happen.
        base_epoch = int(datetime(2026, 1, 1, tzinfo=timezone.utc).timestamp())
        for si, sample in enumerate(ds):
            src = sample["metadata"]["source"]
            stats["n_samples"] += 1
            stats["sources_used"].append(src)

            per_slot: Dict[Tuple[str, str], List[Tuple[int, str]]] = {}
            for line in sample["context"].splitlines():
                line = line.strip()
                m = re.match(r"^(\d+)\.\s*(.+)$", line)
                if not m:
                    continue
                idx = int(m.group(1))
                text = m.group(2).strip()
                triple = _parse_mab_fact(text)
                if triple is None:
                    stats["n_facts_skipped"] += 1
                    continue
                subj, pred, obj = triple
                per_slot.setdefault((subj, pred), []).append((idx, obj))
                stats["n_facts_parsed"] += 1

            for (subj, pred), arrivals in per_slot.items():
                arrivals.sort(key=lambda x: x[0])
                stats["n_slots"] += 1
                if len(arrivals) > 1:
                    stats["n_contested_slots"] += 1
                # Namespace subject with source so the 8 sub-datasets
                # don't collide.
                subj_ns = f"{src}::{subj}"
                entity = stable_entity_id(subj_ns)
                attr = safe_attribute(pred)
                gt = arrivals[-1][1]  # later arrival wins
                for order_i, (fact_idx, obj) in enumerate(arrivals):
                    # We stamp valid_time so the earlier fact's lower
                    # bound is earlier than the later fact's — this
                    # matches how a real memory store would ingest
                    # them.
                    lower = base_epoch + fact_idx * 60  # 1-minute
                                                        # spacing
                    upper = None
                    rec = {
                        "entity_id": entity,
                        "attribute": attr,
                        "value": obj,
                        "ep_kind": "MEASURED",
                        "ep_specificity": 0,
                        "ep_confidence": 1.0,
                        "valid_time_lower_epoch": lower,
                        "valid_time_upper_epoch": upper,
                        "sources": [f"mab_{src}_{fact_idx}"],
                        "ground_truth_survivor": gt,
                        "dataset_metadata": {
                            "sub_dataset": src,
                            "sample_idx": si,
                            "subject": subj,
                            "predicate": pred,
                            "fact_index": fact_idx,
                            "arrival_order_in_slot": order_i,
                            "slot_arrivals_count": len(arrivals),
                        },
                    }
                    emit(fh, rec)
    finally:
        fh.close()
    return stats


# --------------------------------------------------------------------
# Dataset B: LongMemEval knowledge-update pairs.
# --------------------------------------------------------------------

def normalize_lme(source_json: str, out_path: str,
                  dataset_metadata: Dict[str, Any]) -> Dict[str, Any]:
    """
    knowledge-update questions have exactly two answer sessions; the
    LATER session (by haystack_dates) contains the up-to-date value
    (the benchmark's ground-truth answer). We replay each pair as two
    writes on the same slot, with the pair's `question_id` as
    slot-key.

    We record the benchmark's `answer` string as the ground truth. The
    challenge: the raw session content is a free-text conversation, not
    a structured fact. We do NOT try to extract the "before" value from
    session 0 — the benchmark itself doesn't require it. We use
    "<earlier_value>" as a synthetic filler value for the first write,
    and the benchmark's actual `answer` as the value for the second
    write. That preserves the two-write shape without pretending we
    can NLP-parse the earlier value out of the conversation.

    Ground truth = the later value = the benchmark's `answer`.
    """
    with open(source_json) as f:
        d = json.load(f)
    kus = [x for x in d if x["question_type"] == "knowledge-update"]

    stats = {
        "n_ku_samples": len(kus),
        "n_slots": len(kus),
        "n_writes": 0,
        "n_contested_slots": len(kus),  # every KU sample contests
    }

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    fh = open(out_path, "w")
    try:
        for x in kus:
            qid = x["question_id"]
            entity = stable_entity_id(f"lme::{qid}")
            attr = safe_attribute(f"ku_{qid}"[:30])
            gt = x["answer"]
            dates = x.get("haystack_dates") or []
            ep_lower_1 = epoch_of(dates[0]) if dates else None
            ep_lower_2 = epoch_of(dates[1]) if len(dates) > 1 else (
                ep_lower_1 + 3600 if ep_lower_1 is not None else None)
            base = int(datetime(2026, 1, 1, tzinfo=timezone.utc).timestamp())
            if ep_lower_1 is None:
                ep_lower_1 = base
            if ep_lower_2 is None:
                ep_lower_2 = ep_lower_1 + 3600

            # Earlier write: synthetic placeholder value. Its role in
            # the replay is to make the slot contested; its content
            # is intentionally distinct from the ground truth.
            earlier_val = f"__before__::{qid}"
            for order_i, (val, ep, sess_idx) in enumerate([
                (earlier_val, ep_lower_1, 0),
                (gt, ep_lower_2, 1),
            ]):
                rec = {
                    "entity_id": entity,
                    "attribute": attr,
                    "value": val,
                    "ep_kind": "MEASURED",
                    "ep_specificity": 0,
                    "ep_confidence": 1.0,
                    "valid_time_lower_epoch": ep,
                    "valid_time_upper_epoch": None,
                    "sources": [f"lme_{qid}_sess{sess_idx}"],
                    "ground_truth_survivor": gt,
                    "dataset_metadata": {
                        "question_id": qid,
                        "question": x["question"],
                        "question_type": "knowledge-update",
                        "arrival_order_in_slot": order_i,
                        "haystack_date": dates[sess_idx] if sess_idx < len(dates) else None,
                    },
                }
                emit(fh, rec)
                stats["n_writes"] += 1
    finally:
        fh.close()
    return stats


# --------------------------------------------------------------------
# Dataset C: MQuAKE edit chains.
# --------------------------------------------------------------------

def normalize_mquake(source_json: str, out_path: str,
                     dataset_metadata: Dict[str, Any]) -> Dict[str, Any]:
    """
    MQuAKE-CF-3k has counterfactual edits. Each case has 1+ rewrites of
    the form (subject, relation_id, target_true, target_new). Replay
    each rewrite as two writes on the same slot:
      1. target_true value  (arrival 0)
      2. target_new  value  (arrival 1)

    Ground truth = target_new (the counterfactual edit is what the
    benchmark expects downstream reasoning to reflect).
    """
    with open(source_json) as f:
        d = json.load(f)

    stats = {
        "n_cases": len(d),
        "n_rewrites": 0,
        "n_slots": 0,
        "n_writes": 0,
        "n_contested_slots": 0,
        "n_hops_distribution": {},
    }

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    fh = open(out_path, "w")
    try:
        base = int(datetime(2026, 1, 1, tzinfo=timezone.utc).timestamp())
        per_slot_seen: set = set()
        for case in d:
            case_id = case["case_id"]
            rewrites = case.get("requested_rewrite", [])
            n_hops = len(rewrites)
            stats["n_hops_distribution"][n_hops] = (
                stats["n_hops_distribution"].get(n_hops, 0) + 1)
            for ri, rw in enumerate(rewrites):
                subj = rw["subject"]
                pred = rw["relation_id"]
                target_true = rw["target_true"]["str"]
                target_new = rw["target_new"]["str"]
                # Namespace: case_id keeps otherwise-identical
                # rewrites across cases as distinct slots (MQuAKE
                # edits are per-case counterfactuals, not global).
                subj_ns = f"mquake::case{case_id}::{subj}"
                entity = stable_entity_id(subj_ns)
                attr = safe_attribute(pred)
                slot_key = (entity, attr)
                if slot_key not in per_slot_seen:
                    per_slot_seen.add(slot_key)
                    stats["n_slots"] += 1
                stats["n_rewrites"] += 1

                gt = target_new
                for order_i, (val, tag) in enumerate([
                    (target_true, "target_true"),
                    (target_new, "target_new"),
                ]):
                    ep = base + case_id * 100 + ri * 10 + order_i
                    rec = {
                        "entity_id": entity,
                        "attribute": attr,
                        "value": val,
                        "ep_kind": "MEASURED",
                        "ep_specificity": 0,
                        "ep_confidence": 1.0,
                        "valid_time_lower_epoch": ep,
                        "valid_time_upper_epoch": None,
                        "sources": [f"mquake_case{case_id}_rw{ri}_{tag}"],
                        "ground_truth_survivor": gt,
                        "dataset_metadata": {
                            "case_id": case_id,
                            "rewrite_index": ri,
                            "n_hops_in_case": n_hops,
                            "subject": subj,
                            "relation_id": pred,
                            "target_true": target_true,
                            "target_new": target_new,
                            "arrival_order_in_slot": order_i,
                            "value_role": tag,
                        },
                    }
                    emit(fh, rec)
                    stats["n_writes"] += 1
        stats["n_contested_slots"] = stats["n_slots"]
    finally:
        fh.close()
    return stats


# --------------------------------------------------------------------
# Dataset D: Dong Book-Author (VLDB 2009).
# --------------------------------------------------------------------
#
# 894 bookstores × 1265 books × 33971 assertions, gold standard for 100
# ISBN-10 books (book_golden.txt). This is the classic data-fusion
# workload where SOURCE RELIABILITY drives the correct answer — not
# arrival order (which is what MemoryAgentBench / LongMemEval / MQuAKE
# encode).
#
# --- The independence constraint ---------------------------------------
# The F13 mapping rule MUST be computable BEFORE peeking at the golden
# answer. Dong's Table 7 reports per-source "Accu" numbers computed by
# their SIM algorithm, but SIM's output is a truth-discovery result —
# using it as a source-tier proxy for KNDB is peeking at the answer by
# proxy. We reject that path.
#
# Instead we compute two structural properties of each source directly
# from `book.txt`, WITHOUT touching book_golden.txt:
#
#   n_listings(src)     = number of (isbn,author-list) rows the source
#                         provides across the entire corpus. Documented
#                         in Dong et al. Table 7 column "#Books".
#   canon_rate(src)     = fraction of the source's author fields that
#                         are in canonical "Lastname, Firstname" form
#                         (i.e., contain a comma). Sources that publish
#                         canonical bibliographic strings are more
#                         likely to be primary-catalog sources
#                         (Library-of-Congress-style feed) than scraped
#                         aggregators. This is a proxy, not a proof.
#
# --- The mapping rule --------------------------------------------------
# Given a top-K parameter (K in {10, 25, 50, 100, 200} for sensitivity
# analysis), sources are tiered by n_listings desc:
#
#   Tier A (top-K/2 by n, AND canon_rate >= 0.5):
#       ep_kind = MEASURED,   ep_confidence = 1.0
#   Tier B (rest of top-K by n):
#       ep_kind = INFERRED,   ep_confidence = 0.7
#   Tier C (all other sources):
#       ep_kind = DERIVED,    ep_confidence = 0.4  (needs sources[])
#
# Rationale: KNDB's lattice ranks MEASURED > INFERRED > DERIVED. If
# our structural tiering is a useful signal, Tier-A assertions should
# survive contention. If it isn't (i.e., raw #Books is a poor proxy for
# author-list correctness), KNDB won't outperform. The sensitivity
# analysis over K will show whether the choice of K matters.
#
# The canon_rate >= 0.5 cutoff for Tier A is documented in the README;
# 0.5 is the midpoint of the [0,1] range with no ground-truth tuning.

def _bookauthor_load(source_dir: str) -> Tuple[
        List[Tuple[str, str, str, str]], Dict[str, str]]:
    """
    Read book.txt (assertions) and book_golden.txt (ground truth).
    Returns (assertions, gold) where assertions is a list of
    (source, isbn, title, author_list) tuples and gold maps ISBN -> gold
    author string.
    """
    assertions: List[Tuple[str, str, str, str]] = []
    with open(os.path.join(source_dir, "book.txt"), errors="replace") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 4:
                continue
            src, isbn, title, authors = (parts[0].strip(), parts[1].strip(),
                                         parts[2].strip(), parts[3].strip())
            if not src or not isbn:
                continue
            assertions.append((src, isbn, title, authors))

    gold: Dict[str, str] = {}
    with open(os.path.join(source_dir, "book_golden.txt"),
              errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            parts = line.split("\t", 1)
            if len(parts) < 2:
                continue
            gold[parts[0].strip()] = parts[1].strip()
    return assertions, gold


def _bookauthor_source_stats(
        assertions: List[Tuple[str, str, str, str]]
        ) -> Dict[str, Tuple[int, float, float]]:
    """
    Per-source structural metrics — all computed WITHOUT the golden
    answer.

    Returns {src -> (n_listings, non_blank_rate, canon_rate)}.
    """
    from collections import defaultdict
    per_src: Dict[str, List[str]] = defaultdict(list)
    for src, _isbn, _title, authors in assertions:
        per_src[src].append(authors)
    out: Dict[str, Tuple[int, float, float]] = {}
    blank_markers = {"", "not available", "n/a", "none"}
    for src, alist in per_src.items():
        n = len(alist)
        n_non_blank = sum(1 for a in alist
                          if a.strip().lower() not in blank_markers)
        n_canon = sum(1 for a in alist if "," in a)
        out[src] = (n, n_non_blank / n, n_canon / n)
    return out


def normalize_bookauthor_f14(source_dir: str, out_path: str,
                             top_k: int,
                             n_adversarial_per_isbn: int,
                             adversarial_strategy: str = "scrambled",
                             adv_seed: int = 20260714,
                             ) -> Dict[str, Any]:
    """
    F14 variant of the Book-Author normalizer.

    Ground-truth policy (stated up front, does NOT adapt to outcomes):
      A MEASURED value beats an INFERRED value regardless of the
      INFERRED value's asserted confidence. This is the paper's
      epistemic claim: confidence is a self-report, kind is an
      epistemic act.

    Threat model (stated up front):
      A hostile / miscalibrated writer asserts HIGH confidence on an
      INFERRED value. Real-world analogue: LLM-generated content that
      hallucinates values but self-reports as certain; a malicious
      agent poisoning a knowledge store by claiming high credibility
      on a fabricated fact.

    Mapping (revised from F13 to make kind vs. confidence DISAGREE):

      Tier A (top-K/2 by n_listings AND canon_rate >= 0.5):
          ep_kind = MEASURED
          ep_confidence uniform in [0.5, 0.9]   (honest uncertainty)
      Tier B (rest of top-K by n_listings):
          ep_kind = INFERRED
          ep_confidence uniform in [0.4, 0.7]
      Tier C (everything else):
          ep_kind = DERIVED
          ep_confidence uniform in [0.2, 0.5]

      Adversarial injections (N per gold ISBN):
          value = an INCORRECT author string (see `adversarial_strategy`)
          ep_kind = INFERRED
          ep_specificity = 0
          ep_confidence uniform in [0.95, 1.0]
          sources = ['adversarial_agent_{i}']

    Confidence draws use a deterministic seeded RNG (seed=`adv_seed`
    XOR the trace-record's index) so the workload is bit-for-bit
    reproducible.

    Independence from ground truth: the tier assignment (kind + conf
    RANGE) still depends only on (n_listings, canon_rate) — structural
    properties of `book.txt`. Only the specific conf sample within the
    range depends on the seeded RNG. Adversarial injections do NOT
    read `book_golden.txt` to decide who to attack — every gold ISBN
    gets N injections.

    `adversarial_strategy`:
      "scrambled" — the wrong value is a real author name lifted
                    from a DIFFERENT gold ISBN in the dataset (a
                    plausible-looking but wrong answer).
      "fabricated" — the wrong value is a literal fabrication like
                    "John Doe" / "Jane Smith".

    Injection timing: adversarial rows are appended at RANDOM positions
    of the trace using the same seed. That way "adversarial is last
    committer" happens by chance ~N/(N+n_honest) of the time per ISBN.
    """
    import random as _random

    assertions, gold = _bookauthor_load(source_dir)
    src_stats = _bookauthor_source_stats(assertions)

    sorted_by_n = sorted(src_stats.items(), key=lambda kv: -kv[1][0])
    top_k_sources = {s for s, _ in sorted_by_n[:top_k]}
    half_k = max(1, top_k // 2)

    def tier_of(src: str) -> Tuple[str, Tuple[float, float]]:
        stats = src_stats[src]
        if src in top_k_sources:
            rank = next(i for i, (s, _) in enumerate(sorted_by_n)
                        if s == src)
            if rank < half_k and stats[2] >= 0.5:
                return ("MEASURED", (0.5, 0.9))
            return ("INFERRED", (0.4, 0.7))
        return ("DERIVED", (0.2, 0.5))

    # Confidence RNG: derived from adv_seed per-record index for
    # reproducibility.
    def _conf_sample(low: float, high: float, idx: int) -> float:
        rng = _random.Random(adv_seed ^ idx)
        return low + (high - low) * rng.random()

    stats_out: Dict[str, Any] = {
        "n_sources_total": len(src_stats),
        "n_sources_top_k": len(top_k_sources),
        "top_k_parameter": top_k,
        "n_gold_isbns": len(gold),
        "n_assertions_all": len(assertions),
        "n_adversarial_per_isbn": n_adversarial_per_isbn,
        "adversarial_strategy": adversarial_strategy,
        "adv_seed": adv_seed,
        "tier_counts": {"MEASURED": 0, "INFERRED": 0, "DERIVED": 0,
                        "ADVERSARIAL_INFERRED": 0},
    }

    # 1) Emit honest assertions with F14 tier-based conf ranges.
    base_epoch = int(datetime(2026, 1, 1, tzinfo=timezone.utc).timestamp())
    src_epoch = {s: base_epoch + i * 60
                 for i, (s, _) in enumerate(sorted_by_n)}
    honest_rows: List[Dict[str, Any]] = []
    idx = 0
    for src, isbn, title, authors in assertions:
        if isbn not in gold:
            continue
        if not authors.strip() or authors.strip().lower() in (
                "not available", "n/a", "none"):
            continue
        kind, (lo, hi) = tier_of(src)
        conf = _conf_sample(lo, hi, idx)
        stats_out["tier_counts"][kind] += 1
        entity = stable_entity_id(f"bookauthor::{isbn}")
        attr = safe_attribute("author")
        gt = gold.get(isbn)
        honest_rows.append({
            "entity_id": entity,
            "attribute": attr,
            "value": authors,
            "ep_kind": kind,
            "ep_specificity": 0,
            "ep_confidence": round(conf, 6),
            "valid_time_lower_epoch": src_epoch[src],
            "valid_time_upper_epoch": None,
            "sources": (None if kind == "MEASURED"
                        else [f"bookstore::{src}"]),
            "ground_truth_survivor": gt,
            "dataset_metadata": {
                "isbn": isbn,
                "title": title,
                "source_name": src,
                "source_n_listings": src_stats[src][0],
                "source_canon_rate": src_stats[src][2],
                "tier_top_k": top_k,
                "assigned_tier": ("A" if kind == "MEASURED"
                                  else ("B" if kind == "INFERRED"
                                        else "C")),
                "record_role": "honest",
                "trace_index": idx,
            },
        })
        idx += 1

    # 2) Build a pool of "wrong" answers for `scrambled` strategy: a
    # list of author-list strings from OTHER gold ISBNs.
    gold_isbns = sorted(gold.keys())
    gold_answers = [gold[i] for i in gold_isbns]

    def wrong_value_for_isbn(isbn: str, i: int) -> str:
        if adversarial_strategy == "fabricated":
            names = ["John Doe", "Jane Smith", "Alex Roe",
                     "Chris Poe", "Sam Foe"]
            return names[i % len(names)]
        if adversarial_strategy == "sybil":
            # F16 Sybil variant: EVERY adversarial agent shares the SAME
            # wrong value per ISBN. This bootstraps mutual "agreement"
            # among the N Sybil identities so agreement-driven
            # truth-discovery algorithms (TruthFinder/CRH/CATD/ACCU)
            # can be fooled at high N. Deterministic per ISBN only
            # (index `i` is IGNORED).
            h = hashlib.blake2b(f"{isbn}_sybil".encode(),
                                digest_size=4).digest()
            pool_idx = int.from_bytes(h, "big") % len(gold_answers)
            if gold_answers[pool_idx] == gold[isbn]:
                pool_idx = (pool_idx + 1) % len(gold_answers)
            return gold_answers[pool_idx]
        # scrambled: pick a gold answer from a DIFFERENT ISBN.
        # deterministic per (isbn, i) so the run is reproducible.
        h = hashlib.blake2b(f"{isbn}_{i}".encode(), digest_size=4).digest()
        pool_idx = int.from_bytes(h, "big") % len(gold_answers)
        if gold_answers[pool_idx] == gold[isbn]:
            pool_idx = (pool_idx + 1) % len(gold_answers)
        return gold_answers[pool_idx]

    # 3) Emit N adversarial writes per gold ISBN.
    adv_rows: List[Dict[str, Any]] = []
    adv_base_epoch = base_epoch + len(sorted_by_n) * 60 + 3600
    for isbn in gold_isbns:
        entity = stable_entity_id(f"bookauthor::{isbn}")
        attr = safe_attribute("author")
        gt = gold[isbn]
        for i in range(n_adversarial_per_isbn):
            conf = _conf_sample(0.95, 1.0, idx)
            adv_rows.append({
                "entity_id": entity,
                "attribute": attr,
                "value": wrong_value_for_isbn(isbn, i),
                "ep_kind": "INFERRED",
                "ep_specificity": 0,
                "ep_confidence": round(conf, 6),
                "valid_time_lower_epoch": adv_base_epoch + i * 60,
                "valid_time_upper_epoch": None,
                "sources": [f"adversarial_agent_{i}"],
                "ground_truth_survivor": gt,
                "dataset_metadata": {
                    "isbn": isbn,
                    "source_name": f"adversarial_agent_{i}",
                    "record_role": "adversarial",
                    "trace_index": idx,
                    "strategy": adversarial_strategy,
                    "tier_top_k": top_k,
                    "assigned_tier": "ADV",
                },
            })
            stats_out["tier_counts"]["ADVERSARIAL_INFERRED"] += 1
            idx += 1

    # 4) Interleave: place adversarial rows at random positions using
    # the same seed. Adversarial rows can arrive before / after / in-
    # the-middle-of honest arrivals per slot — that is the threat
    # model. Only the position is random; the (kind, conf, value)
    # payload is fully deterministic.
    trace: List[Dict[str, Any]] = list(honest_rows)
    pos_rng = _random.Random(adv_seed)
    for rec in adv_rows:
        insert_at = pos_rng.randrange(len(trace) + 1)
        trace.insert(insert_at, rec)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as fh:
        for rec in trace:
            emit(fh, rec)

    stats_out["n_honest_writes"] = len(honest_rows)
    stats_out["n_adversarial_writes"] = len(adv_rows)
    stats_out["n_total_writes"] = len(trace)
    return stats_out


# --------------------------------------------------------------------
# Dataset E: Zheng VLDB'17 d_sentiment (F15).
# --------------------------------------------------------------------
#
# See bench/datasets/zheng_sentiment/README.md for the pre-registered
# mapping rationale. In brief:
#
#   * Independent per-worker quality signal = accuracy on a disjoint
#     20-item qualification test. Computed WITHOUT touching main-task
#     truth.csv.
#   * K-parametric tier assignment: top K/3 by quali_acc -> MEASURED,
#     middle third of top-K -> INFERRED, bottom third + rest -> DERIVED.
#   * F14-style confidence ranges: MEASURED [0.5,0.9], INFERRED [0.4,0.7],
#     DERIVED [0.2,0.5], adversarial INFERRED [0.95,1.0].
#   * Adversarial: N flipped-gold INFERRED writes per contested slot,
#     inserted at random positions (deterministic seed).

def _zheng_sentiment_load(source_dir: str) -> Dict[str, Any]:
    import csv
    from collections import defaultdict

    answers: List[Tuple[str, str, str]] = []
    with open(os.path.join(source_dir, "answer.csv")) as f:
        r = csv.DictReader(f)
        for row in r:
            answers.append((row["id"], row["worker"], row["answer"]))

    truth: Dict[str, str] = {}
    with open(os.path.join(source_dir, "truth.csv")) as f:
        r = csv.DictReader(f)
        for row in r:
            truth[row["q"]] = row["truth"]

    quali_truth: Dict[str, str] = {}
    with open(os.path.join(source_dir, "quali_truth.csv")) as f:
        r = csv.DictReader(f)
        for row in r:
            quali_truth[row["q"]] = row["truth"]

    quali_resp: Dict[str, List[Tuple[str, str]]] = defaultdict(list)
    with open(os.path.join(source_dir, "quali.csv")) as f:
        r = csv.DictReader(f)
        for row in r:
            quali_resp[row["worker"]].append((row["id"], row["answer"]))

    return {
        "answers": answers,
        "truth": truth,
        "quali_truth": quali_truth,
        "quali_resp": quali_resp,
    }


def _zheng_sentiment_worker_scores(
        quali_truth: Dict[str, str],
        quali_resp: Dict[str, List[Tuple[str, str]]]
        ) -> Dict[str, float]:
    """Per-worker qualification accuracy. Gold-independent from main task."""
    out: Dict[str, float] = {}
    for w, resps in quali_resp.items():
        n_ok = 0
        n_tot = 0
        for qid, a in resps:
            if qid in quali_truth:
                n_tot += 1
                if quali_truth[qid] == a:
                    n_ok += 1
        if n_tot > 0:
            out[w] = n_ok / n_tot
    return out


def normalize_zheng_sentiment_f15(source_dir: str, out_path: str,
                                  top_k: int,
                                  n_adversarial_per_slot: int,
                                  adv_seed: int = 20260715,
                                  adversarial_strategy: str = "flip_binary",
                                  ) -> Dict[str, Any]:
    """
    F15 normalizer for Zheng VLDB'17 d_sentiment with adversarial injection.

    Ground-truth policy (same as F14): a MEASURED value beats an INFERRED
    value regardless of the INFERRED value's asserted confidence.

    Threat model (same as F14): hostile writer asserts HIGH confidence on
    an INFERRED value that is the wrong-class label (binary flip since
    d_sentiment is a 2-class task).

    F17 note (`adversarial_strategy`):
      "flip_binary"  — F15 semantics: each adversarial write on a gold
                       slot uses the flipped binary label. Because
                       d_sentiment is a 2-class task the flipped label
                       is UNIQUE, so all N adversaries on a slot use the
                       same value by construction (Sybil-by-construction).
      "sybil"        — F17 explicit Sybil label. Semantics IDENTICAL to
                       flip_binary on Zheng (binary => the wrong label
                       is unique), but recorded explicitly in
                       `dataset_metadata.strategy` so the F17 F16-parity
                       grid can be identified in downstream tooling.
      NB: on Book-Author (multi-value slots) sybil vs scrambled diverge
      meaningfully; on Zheng they cannot. F17 documents this in
      `stage3_zheng_sybil.md`.
    """
    import random as _random

    data = _zheng_sentiment_load(source_dir)
    answers = data["answers"]
    truth = data["truth"]
    quali_truth = data["quali_truth"]
    quali_resp = data["quali_resp"]

    wscores = _zheng_sentiment_worker_scores(quali_truth, quali_resp)

    # Rank workers by quali_acc desc; stable tie-break on worker_id.
    sorted_workers = sorted(wscores.items(), key=lambda kv: (-kv[1], kv[0]))
    all_worker_ids = {w for w, _ in sorted_workers}
    top_k = min(top_k, len(sorted_workers))
    top_k_set = {w for w, _ in sorted_workers[:top_k]}
    a_third = max(1, top_k // 3)
    b_third_end = min(top_k, 2 * a_third)
    tier_A = {w for w, _ in sorted_workers[:a_third]}
    tier_B = {w for w, _ in sorted_workers[a_third:b_third_end]}
    # tier_C = everyone else (bottom of top-K + workers outside top-K
    # + any worker with no quali score, though for d_sentiment all
    # workers have quali coverage).

    tier_confs = {
        "MEASURED": (0.5, 0.9),
        "INFERRED": (0.4, 0.7),
        "DERIVED": (0.2, 0.5),
    }

    def tier_of(w: str) -> str:
        if w in tier_A:
            return "MEASURED"
        if w in tier_B:
            return "INFERRED"
        return "DERIVED"

    def _conf_sample(low: float, high: float, idx: int) -> float:
        rng = _random.Random(adv_seed ^ idx)
        return low + (high - low) * rng.random()

    # Binary label decode: Zheng uses "1" / "0" strings.
    def _decode(v: str) -> str:
        return "pos" if str(v).strip() == "1" else "neg"

    def _decode_flip(v: str) -> str:
        return "neg" if str(v).strip() == "1" else "pos"

    stats_out: Dict[str, Any] = {
        "n_workers_total": len(all_worker_ids),
        "n_workers_with_quali": len(wscores),
        "n_workers_top_k": len(top_k_set),
        "top_k_parameter": top_k,
        "tier_sizes": {"A": len(tier_A), "B": len(tier_B),
                       "C": len(all_worker_ids) - len(tier_A) - len(tier_B)},
        "n_gold_slots": len(truth),
        "n_answers_total": len(answers),
        "n_adversarial_per_slot": n_adversarial_per_slot,
        "adversarial_strategy": adversarial_strategy,
        "adv_seed": adv_seed,
        "tier_counts": {"MEASURED": 0, "INFERRED": 0, "DERIVED": 0,
                        "ADVERSARIAL_INFERRED": 0},
        "quali_acc_by_tier": {
            "A_min": min((wscores[w] for w in tier_A), default=None),
            "A_max": max((wscores[w] for w in tier_A), default=None),
            "B_min": min((wscores[w] for w in tier_B), default=None),
            "B_max": max((wscores[w] for w in tier_B), default=None),
        },
    }

    base_epoch = int(datetime(2026, 1, 1, tzinfo=timezone.utc).timestamp())

    honest_rows: List[Dict[str, Any]] = []
    idx = 0
    for row_i, (qid, w, ans) in enumerate(answers):
        if qid not in truth:
            continue  # only score gold slots
        kind = tier_of(w)
        lo, hi = tier_confs[kind]
        conf = _conf_sample(lo, hi, idx)
        stats_out["tier_counts"][kind] += 1
        entity = stable_entity_id(f"zheng_sentiment::{qid}")
        attr = safe_attribute("sentiment")
        val = _decode(ans)
        gt = _decode(truth[qid])
        honest_rows.append({
            "entity_id": entity,
            "attribute": attr,
            "value": val,
            "ep_kind": kind,
            "ep_specificity": 0,
            "ep_confidence": round(conf, 6),
            "valid_time_lower_epoch": base_epoch + row_i * 60,
            "valid_time_upper_epoch": None,
            "sources": (None if kind == "MEASURED"
                        else [f"zheng_worker::{w}"]),
            "ground_truth_survivor": gt,
            "dataset_metadata": {
                "question_id": qid,
                "worker_id": w,
                "worker_quali_acc": round(wscores.get(w, 0.0), 4),
                "tier_top_k": top_k,
                "assigned_tier": ("A" if kind == "MEASURED"
                                  else ("B" if kind == "INFERRED"
                                        else "C")),
                "record_role": "honest",
                "trace_index": idx,
            },
        })
        idx += 1

    # Adversarial: one flipped-gold write per (question, i) pair.
    adv_rows: List[Dict[str, Any]] = []
    adv_base_epoch = base_epoch + len(answers) * 60 + 3600
    for qid, gold_raw in sorted(truth.items()):
        entity = stable_entity_id(f"zheng_sentiment::{qid}")
        attr = safe_attribute("sentiment")
        gt = _decode(gold_raw)
        for i in range(n_adversarial_per_slot):
            conf = _conf_sample(0.95, 1.0, idx)
            adv_rows.append({
                "entity_id": entity,
                "attribute": attr,
                "value": _decode_flip(gold_raw),
                "ep_kind": "INFERRED",
                "ep_specificity": 0,
                "ep_confidence": round(conf, 6),
                "valid_time_lower_epoch": adv_base_epoch + i * 60,
                "valid_time_upper_epoch": None,
                "sources": [f"adversarial_agent_{i}"],
                "ground_truth_survivor": gt,
                "dataset_metadata": {
                    "question_id": qid,
                    "record_role": "adversarial",
                    "trace_index": idx,
                    # F17: record the *label* the caller asked for so
                    # downstream tooling can tell Sybil (F17) traces from
                    # F15 flip traces even though the value is
                    # bit-identical on binary d_sentiment.
                    "strategy": adversarial_strategy,
                    "tier_top_k": top_k,
                    "assigned_tier": "ADV",
                },
            })
            stats_out["tier_counts"]["ADVERSARIAL_INFERRED"] += 1
            idx += 1

    # Random-position interleave; deterministic per adv_seed.
    trace: List[Dict[str, Any]] = list(honest_rows)
    pos_rng = _random.Random(adv_seed)
    for rec in adv_rows:
        insert_at = pos_rng.randrange(len(trace) + 1)
        trace.insert(insert_at, rec)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as fh:
        for rec in trace:
            emit(fh, rec)

    stats_out["n_honest_writes"] = len(honest_rows)
    stats_out["n_adversarial_writes"] = len(adv_rows)
    stats_out["n_total_writes"] = len(trace)
    return stats_out


def normalize_bookauthor(source_dir: str, out_path: str,
                         top_k: int,
                         gold_only: bool = True,
                         dataset_metadata: Optional[Dict[str, Any]] = None
                         ) -> Dict[str, Any]:
    """
    Emit a normalized replay trace. When gold_only=True (default), only
    assertions on ISBNs with a gold-standard author list are emitted;
    that's 100 books × ~29 assertions/book = ~2900 writes, all of them
    contested by value. The gold-only subset is what we score AA over.

    top_k: the sensitivity-analysis parameter. Sources ranked top_k by
    n_listings become Tier A/B; the rest are Tier C.
    """
    assertions, gold = _bookauthor_load(source_dir)
    src_stats = _bookauthor_source_stats(assertions)

    # Rank sources by n_listings desc — this is our ordering axis, and
    # is documented in Dong et al. Table 7 column "#Books".
    sorted_by_n = sorted(src_stats.items(), key=lambda kv: -kv[1][0])
    top_k_sources = {s for s, _ in sorted_by_n[:top_k]}
    half_k = max(1, top_k // 2)

    def tier_of(src: str) -> Tuple[str, float]:
        stats = src_stats[src]
        if src in top_k_sources:
            rank = next(i for i, (s, _) in enumerate(sorted_by_n) if s == src)
            if rank < half_k and stats[2] >= 0.5:  # canon_rate >= 0.5
                return ("MEASURED", 1.0)
            return ("INFERRED", 0.7)
        return ("DERIVED", 0.4)

    stats_out: Dict[str, Any] = {
        "n_sources_total": len(src_stats),
        "n_sources_top_k": len(top_k_sources),
        "top_k_parameter": top_k,
        "n_gold_isbns": len(gold),
        "n_assertions_all": len(assertions),
        "tier_counts": {"MEASURED": 0, "INFERRED": 0, "DERIVED": 0},
    }

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    fh = open(out_path, "w")
    n_emitted = 0
    base_epoch = int(datetime(2026, 1, 1, tzinfo=timezone.utc).timestamp())
    # Assign a per-source epoch so KNDB's arrival order is a stable
    # function of the source, not of file-line order. This is important
    # for reproducibility across replays; the epoch itself is not used
    # by any tier-decision logic.
    src_epoch = {s: base_epoch + i * 60
                 for i, (s, _) in enumerate(sorted_by_n)}
    try:
        for src, isbn, title, authors in assertions:
            if gold_only and isbn not in gold:
                continue
            if not authors.strip() or authors.strip().lower() in (
                    "not available", "n/a", "none"):
                # Skip blank claims — they can't win the lattice and
                # blow up the abort count for no informational reason.
                continue
            kind, conf = tier_of(src)
            stats_out["tier_counts"][kind] += 1
            entity = stable_entity_id(f"bookauthor::{isbn}")
            attr = safe_attribute("author")
            gt = gold.get(isbn)
            rec = {
                "entity_id": entity,
                "attribute": attr,
                "value": authors,
                "ep_kind": kind,
                "ep_specificity": 0,
                "ep_confidence": conf,
                "valid_time_lower_epoch": src_epoch[src],
                "valid_time_upper_epoch": None,
                # KNDB's rules require sources[] for INFERRED and
                # DERIVED; skip for MEASURED (R3).
                "sources": (None if kind == "MEASURED"
                            else [f"bookstore::{src}"]),
                "ground_truth_survivor": gt,
                "dataset_metadata": {
                    "isbn": isbn,
                    "title": title,
                    "source_name": src,
                    "source_n_listings": src_stats[src][0],
                    "source_canon_rate": src_stats[src][2],
                    "tier_top_k": top_k,
                    "assigned_tier": ("A" if kind == "MEASURED"
                                      else ("B" if kind == "INFERRED"
                                            else "C")),
                },
            }
            emit(fh, rec)
            n_emitted += 1
    finally:
        fh.close()
    stats_out["n_writes_emitted"] = n_emitted
    stats_out["gold_only"] = gold_only
    return stats_out


# --------------------------------------------------------------------
# CLI.
# --------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset",
                    choices=["memoryagentbench", "longmemeval", "mquake",
                             "bookauthor", "bookauthor_f14",
                             "zheng_sentiment_f15"],
                    required=True)
    ap.add_argument("--source", required=True,
                    help="path to source dir (mab / bookauthor) or "
                         "file (lme/mquake)")
    ap.add_argument("--out", required=True,
                    help="path to write normalized.jsonl")
    ap.add_argument("--top-k", type=int, default=50,
                    help="Dong bookauthor: top-K sources by n_listings "
                         "become authority tiers A/B (rest -> C).")
    ap.add_argument("--n-adversarial", type=int, default=0,
                    help="bookauthor_f14: N adversarial INFERRED "
                         "conf=[0.95,1.0] writes per gold ISBN.")
    ap.add_argument("--adv-strategy",
                    choices=["scrambled", "fabricated", "sybil",
                             "flip_binary"],
                    default="scrambled",
                    help="bookauthor_f14 adversarial value strategy; "
                         "zheng_sentiment_f15 supports flip_binary "
                         "(default F15 semantics) and sybil "
                         "(F17 label; identical to flip_binary on "
                         "binary d_sentiment).")
    ap.add_argument("--adv-seed", type=int, default=20260714,
                    help="bookauthor_f14 seed for confidence draws and "
                         "adversarial insertion positions.")
    args = ap.parse_args()

    if args.dataset == "memoryagentbench":
        stats = normalize_mab(args.source, args.out, {})
    elif args.dataset == "longmemeval":
        stats = normalize_lme(args.source, args.out, {})
    elif args.dataset == "mquake":
        stats = normalize_mquake(args.source, args.out, {})
    elif args.dataset == "bookauthor":
        stats = normalize_bookauthor(args.source, args.out, args.top_k)
    elif args.dataset == "bookauthor_f14":
        stats = normalize_bookauthor_f14(
            args.source, args.out, args.top_k,
            args.n_adversarial, args.adv_strategy, args.adv_seed)
    elif args.dataset == "zheng_sentiment_f15":
        # F17: allow --adv-strategy to flow through to Zheng. Default is
        # "flip_binary" (F15 semantics); "sybil" is accepted and mapped
        # to the same construction on this binary task, but recorded
        # explicitly so F17 grid outputs are distinguishable. Reject
        # Book-Author-only strategies.
        zheng_strat = args.adv_strategy
        if zheng_strat in ("scrambled", "fabricated"):
            # These have no analogue on a binary label; treat as request
            # for the F15 default and warn on stderr.
            print(f"[normalize.py] warning: --adv-strategy={zheng_strat} "
                  "not applicable to binary d_sentiment; using "
                  "flip_binary.", file=sys.stderr)
            zheng_strat = "flip_binary"
        stats = normalize_zheng_sentiment_f15(
            args.source, args.out, args.top_k,
            args.n_adversarial, args.adv_seed,
            adversarial_strategy=zheng_strat)
    else:
        print("unknown dataset", file=sys.stderr); return 2

    print(json.dumps({"dataset": args.dataset, "out": args.out,
                      "stats": stats}, indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
