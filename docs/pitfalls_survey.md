# Pitfalls Survey — Live-Verified (M8)

Verified via live WebSearch/WebFetch on 2026-06-30. `[INFERRED]` marks unverifiable items. Supersedes plan.md §8 scaffold.

## 1. CIDR 2027 CFP

Fetched `cidrdb.org/cidr2027/cfp.html` [1]:

- **Page limit:** "must not exceed 6 pages in length including all references and appendix."
- **Deadline:** August 4, 2026, 11:59pm Pacific. **Notification:** Oct 6, 2026. Conference: Jan 24-27, 2027, Amsterdam.
- **Format:** ACM sigconf double-column.
- **Artifact evaluation:** NOT on CFP page — CIDR has none. `[INFERRED]` still ship one.
- **AI disclosure:** NOT on CIDR CFP; ACM umbrella policy governs (§3).

## 2. CIDR 2026 program — closest neighbors

Fetched program page [2]. Adjacent papers:

- **"Supporting Our AI Overlords: Redesigning Data Systems to be Agent-First"** — Liu, Ponnapalli, Shankar, Zeighami et al. (UC Berkeley). Direct competitor framing; they argue agent-first API, KNDB argues agent-first *epistemic state* + provenance in the engine.
- **"Please Don't Kill My Vibe: Empowering Agents with Data Flow Control"** — Summers, Mohammed, Wu (Columbia). Trust/flow overlap.
- **"Deep Research is the New Analytics System"** — Russo, Kraska (MIT).
- **"Making Prompts First-Class Citizens for Adaptive LLM Pipelines"** — Çetintemel et al. (Brown/Northwestern).
- **"A Vision for Autonomous Data Agent Collaboration"** — Eckmann, Binnig (TU Darmstadt).

`[INFERRED]` arXiv IDs — CIDR page lists no arXiv links; do not fabricate IDs.

## 3. ACM AI-disclosure policy

acm.org FAQ page 403'd WebFetch. Quoted from SIGCHI [3] / CACM [4] restatement of ACM's 2023 policy:

> "Generative AI tools and technologies, such as ChatGPT, may not be listed as authors of an ACM published Work. The use of generative AI tools and technologies to create content is permitted but must be fully disclosed in the Work. Basic word processing systems are to be considered exceptions to this disclosure requirement."

**Update:** ACM issued revised authorship policy in June 2026 [4] that "negates some" of the 2023 language. Exact revised text was not extractable — `[UNCERTAIN]`; check `acm.org/publications/policies/new-acm-policy-on-authorship` manually before submission.

## 4. SIGMOD ARI / VLDB reproducibility 2026

- SIGMOD 2026 ARI: "Coming soon" — no checklist yet [5]. `[INFERRED]` design to 2025 ARI as floor.
- VLDB 2027 guidelines require full reproducibility package at initial submission; Docker/OCI container or VM strongly recommended [6][7]. Hardware description required in appendix.
- **For KNDB:** ship Docker image with digest, `make reproduce`, pinned Postgres 17 + ProvSQL SHA, seed 42, kernel + CPU-governor log. Nix optional.

## 5. Fabricated-benchmark / LLM-code retractions (2024-2026)

1. **Springer Nature — "Mastering Machine Learning" (Madhavan, 2025)** retracted after ~2/3 of sampled citations found nonexistent [8].
2. **NeurIPS 2025 — 100 fabricated citations** in accepted papers, five-category taxonomy (arXiv:2602.05930) [9].
3. **arXiv 1-year author-ban (May 2026)** for hallucinated references; rate rose from 1/2,828 (2023) to 1/277 (early 2026) [10][11].
4. **Zhao et al. 2026** audit estimates ~146,932 hallucinated citations in 2025 alone [11].
5. **SWE-Bench Illusion (2025)** + **LessLeak-Bench (2026)** document coding-benchmark contamination [12].

**KNDB implication:** dereference every reference; every benchmark number needs a re-runnable seed.

## 6. Reviewer-detected LLM tells (2025-2026)

- **Em-dash overuse.** Freeburg, arXiv:2603.27006 (Mar 2026) [13] — 0.0-9.1 per 1000 words across 12 models; persists when markdown suppressed. Scientific-abstract em-dash rate >2× from 2021→2025.
- **Nominalizations up; first-person + epistemic-stance markers down** (Jiang & Hyland 2024).
- **Uniform transitions / linguistic homogeneity** — low sentence-structure variance [14].
- **Macro-regularity of paragraph length** — human + zero-shot LLM evaluators converge [14].
- **Excess-vocabulary markers** (arXiv:2406.07016).
- **Tricolons:** NOT documented. `[INFERRED]` — do not claim in paper.

**For KNDB:** human-write intro/contributions/limitations. Vary paragraph length. Cut gratuitous em-dashes.

## 7. Adjacent 2025-2026 preprints (arXiv IDs verified)

- **arXiv:2604.22085** — *Memanto: Typed Semantic Memory* (Abtahi et al., Apr 2026). 13-category typed schema; direct competitor to KNDB typed-atoms.
- **arXiv:2605.11032** — *Portable Agent Memory: Cryptographically-Verified Transfer* (Ravindran, May 2026). Merkle-DAG provenance; direct competitor.
- **arXiv:2601.08323** — *AtomMem: Learnable Dynamic Agentic Memory* (Huo et al., Jan 2026, rev. Mar 2026). Atomic CRUD as RL policy.
- **arXiv:2606.24775** — *Are We Ready For An Agent-Native Memory System?* (Zhou et al., Jun 2026). Survey of 12 memory systems.
- **arXiv:2507.22077** — *From Cloud-Native to Trust-Native* (Li, Jul 2025). Coins "trust-native"; engage directly.
- **arXiv:2412.07986** — *Provenance Analysis and Semiring Semantics for FOL* (Grädel & Tannen, Dec 2024). Theoretical anchor.
- **arXiv:2603.11768** — *Governing Evolving Memory in LLM Agents (SSGM)* (2026).
- **arXiv:2604.02522** — *Opal: Private Memory for Personal AI* (2026).

## 8. MemIR and ATCH verification

- **arXiv:2605.25869** — MemIR, "Mitigating Provenance-Role Collapse in Long-Term Agents via Typed Memory Representation" (Jin et al., May 25 2026). Resolves. **v1 only** — no v2/v3.
- **arXiv:2603.13603** — ATCH, "The Equivalence Theorem: First-Class Relationships for Structurally Complete Database Systems" (Alford, Mar 13 2026). Resolves. **v1 only.**

Both still v1 — no revisions since prior scan. Safe to cite as-is.

## Delta to plan.md §8

**ADD:** "No em-dashes without cause" (§6); "dereference every reference pre-submission" (§5); "cite Liu 'AI Overlords' + Summers 'Vibe' in intro" (§2); "position against Memanto + Portable Agent Memory + AtomMem" (§7).

**EDIT:** "AI-assistance disclosure per ACM policy" → "per revised June-2026 ACM policy; re-verify wording" (§3 `[UNCERTAIN]`). "6 pages" verified — keep firm (§1).

**REMOVE:** Any Agent-3 claim of a CIDR artifact-evaluation track (none exists). Any tricolon-avoidance claim (undocumented).

---

### Sources
[1] cidrdb.org/cidr2027/cfp.html · [2] cidrdb.org/cidr2026/papers.html · [3] medium.com/sigchi/acm-publications-policy-guidance-for-sigchi-venues-87332173aad1 · [4] cacm.acm.org/opinion/generative-artificial-intelligence-policies-under-the-microscope/ · [5] reproducibility.sigmod.org/2026/ · [6] vldb.org/2027/submission-guidelines.html · [7] vldb.org/pvldb/vol17/p4221-hirn.pdf · [8] retractionwatch.com/2025/06/30/springer-nature-book-on-machine-learning-is-full-of-made-up-citations/ · [9] arxiv.org/abs/2602.05930 · [10] nature.com/articles/d41586-026-01595-5 · [11] retractionwatch.com/2026/05/07/one-in-277-pubmed-indexed-papers-in-2026-shows-fabricated-references-says-analysis/ · [12] arxiv.org/abs/2505.08903 · [13] arxiv.org/abs/2603.27006 · [14] pmc.ncbi.nlm.nih.gov/articles/PMC12453209/
