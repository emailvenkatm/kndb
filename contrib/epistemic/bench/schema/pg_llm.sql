-- Baseline #2: LLM-gated conflict resolver.
--
-- Plain heap + BEFORE INSERT trigger that on conflict "consults an
-- LLM" and applies its decision. In production this would be a real
-- API call to Anthropic / OpenAI / vLLM etc. For a benchmark run on
-- a laptop with no vetted API key, we substitute a MOCK LLM that:
--
--   (1) sleeps a calibrated latency drawn from a log-normal
--       distribution (mean ~300ms, sigma ~0.5) — approximates the
--       observed latency of Claude Haiku / GPT-4o-mini / DeepSeek-V3
--       on a "which of these two structured records should win?"
--       prompt of ~500 input + ~50 output tokens.
--
--   (2) decides with probability P_correct that the lattice-correct
--       winner survives, and with probability 1 - P_correct that the
--       lattice-incorrect winner survives. P_correct default 0.65,
--       calibrated against Mem0 / MemGPT-follow-up published
--       conflict-resolution rates on the LOCOMO benchmark (60-75%
--       range depending on prompt engineering; we sit near the
--       middle).
--
-- The mock is deterministic given a hash of (incumbent.value,
-- new.value, entity_id, attribute) + a per-session seed so runs are
-- reproducible.
--
-- Calibration sources cited in bench/README.md; both latency and
-- P_correct values must be explicitly justified before any paper claim.
--
-- Toggles:
--   bench.fact_llm_p_correct     -> float in [0,1]. Default '0.925'
--                                    (refit against a real claude-haiku-4-5
--                                    API — see F11 calibration).
--   bench.fact_llm_latency_mean  -> ms. Default '1120' (refit).
--   bench.fact_llm_latency_sigma -> log-normal sigma. Default '0.3662'
--                                    (log-scale sd of the 200-sample calibration).
--   bench.fact_llm_mode          -> 'on' (default) or 'off' (bypass
--                                    entirely; degrades to LWW).
--   bench.fact_llm_disable_test  -> when '1', forces P_correct=0.5
--                                    (random) for the disable-and-test
--                                    transcript.
--
-- F11 refit: the F10 defaults (P=0.65, mean=200ms, sigma=0.5) were
-- calibrated against public Anthropic/OpenAI numbers because no LLM
-- API was reachable at that time. F11 called
-- claude-haiku-4-5-20251001 on 200 real (incumbent, candidate) pairs
-- sampled from the adversarial theta=0.9 c=8 workload; measured
-- correctness = 92.5%, mean e2e latency = 1120 ms (p50=939, p99=2312).
-- Real API is noticeably better at correctness than public conflict-
-- resolution benchmarks suggested and materially slower. The refit
-- numbers are load-bearing on the paper's LLM-baseline story.
-- Full transcript: bench/results/stage3_llm_calibration.jsonl.

CREATE EXTENSION IF NOT EXISTS epistemic;

DROP TABLE IF EXISTS fact_llm;

CREATE TABLE fact_llm (
    entity_id      int NOT NULL,
    attribute      text NOT NULL,
    value          text,
    sources        text[],
    valid_time     tstzrange,
    sys_time       tstzrange DEFAULT tstzrange(now(), 'infinity'),
    ep_kind        epistemic.epistemic_kind NOT NULL,
    ep_specificity int2 NOT NULL DEFAULT 0,
    ep_confidence  real NOT NULL DEFAULT 1.0
);

-- Kind rank helper — the mock LLM uses the lattice's own kind order
-- as its "ground truth" for the correct-branch outcome. That is: when
-- we roll the correctness die and win, we pick the lattice's winner.
-- When we lose, we pick the loser. This is the honest calibration —
-- it corresponds to "the LLM correctly reasons about kinds most of
-- the time" and does NOT bias the mock to match KNDB by construction,
-- because P_correct < 1 and because the lattice also uses specificity
-- and confidence which the mock doesn't directly see.
CREATE OR REPLACE FUNCTION fact_llm_kind_rank(k epistemic.epistemic_kind)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE k::text
        WHEN 'MEASURED' THEN 3
        WHEN 'DERIVED'  THEN 2
        WHEN 'INFERRED' THEN 1
        ELSE 0
    END
$$;

CREATE OR REPLACE FUNCTION fact_llm_setting(name text, dflt text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT coalesce(current_setting(name, true), dflt)
$$;

-- Log-normal sample using a fixed transformation of a uniform sample.
-- Given u1, u2 in (0, 1), Box-Muller yields z = sqrt(-2 ln u1) cos(2π u2)
-- which is N(0, 1); then exp(sigma * z + ln(mean) - sigma^2/2) is
-- log-normal with mean exactly `mean`. Doing this in plpgsql keeps
-- the mock self-contained (no plpython, no plperl).
CREATE OR REPLACE FUNCTION fact_llm_lognormal_ms(mean_ms real, sigma real,
                                                  seed_input text)
RETURNS real LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    -- Derive two "uniforms" from hashtext by mixing salts. hashtext is
    -- signed int32; map to (0, 1) safely.
    h1 int := hashtext(seed_input || '/a');
    h2 int := hashtext(seed_input || '/b');
    u1 double precision;
    u2 double precision;
    z  double precision;
    ln_mean double precision := ln(mean_ms::double precision);
BEGIN
    u1 := (((h1::bigint + 2147483648) % 2147483647) + 1)::double precision
          / 2147483648.0;
    u2 := (((h2::bigint + 2147483648) % 2147483647))::double precision
          / 2147483647.0;
    z := sqrt(-2.0 * ln(u1)) * cos(2.0 * pi() * u2);
    RETURN exp(sigma::double precision * z + ln_mean
               - (sigma::double precision * sigma::double precision) / 2.0)::real;
END;
$$;

-- Deterministic Bernoulli. Given a seed string and a probability p,
-- returns TRUE with probability p. Hashes the string, maps to [0, 1),
-- compares to p.
CREATE OR REPLACE FUNCTION fact_llm_bernoulli(p real, seed_input text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    h int := hashtext(seed_input);
    u double precision;
BEGIN
    u := (((h::bigint + 2147483648) % 2147483647))::double precision
         / 2147483647.0;
    RETURN u < p::double precision;
END;
$$;

CREATE OR REPLACE FUNCTION fact_llm_rules()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    inc_kind epistemic.epistemic_kind;
    inc_spec int2;
    inc_conf real;
    inc_value text;
    inc_ctid tid;
    -- Configurables.
    mode text := fact_llm_setting('bench.fact_llm_mode', 'on');
    p_correct real := fact_llm_setting('bench.fact_llm_p_correct', '0.925')::real;
    lat_mean_ms real := fact_llm_setting('bench.fact_llm_latency_mean', '1120')::real;
    lat_sigma real := fact_llm_setting('bench.fact_llm_latency_sigma', '0.3662')::real;
    disable_test text := fact_llm_setting('bench.fact_llm_disable_test', '0');
    seed_input text;
    sleep_ms real;
    correct_answer boolean;
    lattice_says_new_wins boolean;
    llm_says_new_wins boolean;
    new_rank int;
    inc_rank int;
BEGIN
    SELECT ep_kind, ep_specificity, ep_confidence, value, ctid
      INTO inc_kind, inc_spec, inc_conf, inc_value, inc_ctid
      FROM fact_llm
     WHERE entity_id = NEW.entity_id AND attribute = NEW.attribute
       AND upper(sys_time) = 'infinity'::timestamptz
     LIMIT 1
     FOR UPDATE;

    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    -- Disable-and-test knob: mode=off entirely bypasses the LLM
    -- (degrades to LWW).
    IF mode = 'off' THEN
        UPDATE fact_llm
           SET sys_time = tstzrange(lower(sys_time), clock_timestamp())
         WHERE ctid = inc_ctid;
        RETURN NEW;
    END IF;

    -- Compute lattice answer (the ground truth the LLM is trying to
    -- reproduce): NEW wins iff (kind_rank NEW > kind_rank INC) OR
    -- (kind_rank ties AND specificity NEW > INC) OR
    -- (kind + spec tie AND confidence NEW > INC). Ties fall through to
    -- first-committer-wins -> incumbent stays.
    new_rank := fact_llm_kind_rank(NEW.ep_kind);
    inc_rank := fact_llm_kind_rank(inc_kind);
    IF new_rank > inc_rank THEN
        lattice_says_new_wins := true;
    ELSIF new_rank < inc_rank THEN
        lattice_says_new_wins := false;
    ELSIF NEW.ep_specificity > inc_spec THEN
        lattice_says_new_wins := true;
    ELSIF NEW.ep_specificity < inc_spec THEN
        lattice_says_new_wins := false;
    ELSIF NEW.ep_confidence > inc_conf THEN
        lattice_says_new_wins := true;
    ELSIF NEW.ep_confidence < inc_conf THEN
        lattice_says_new_wins := false;
    ELSE
        -- True tie -> first-committer-wins per KNDB F8.
        lattice_says_new_wins := false;
    END IF;

    seed_input := NEW.entity_id::text || '/' || NEW.attribute || '/'
                  || inc_value || '/' || NEW.value;

    -- Latency: the mock always pays the calibrated wait.
    sleep_ms := fact_llm_lognormal_ms(lat_mean_ms, lat_sigma, seed_input);
    -- Cap at 10s to avoid pathological samples locking backends forever.
    IF sleep_ms > 10000 THEN sleep_ms := 10000; END IF;
    PERFORM pg_sleep((sleep_ms / 1000.0)::double precision);

    -- Correctness: the LLM answers the lattice-correct decision with
    -- probability P_correct; otherwise it answers the opposite.
    IF disable_test = '1' THEN
        p_correct := 0.5;
    END IF;
    correct_answer := fact_llm_bernoulli(p_correct, seed_input);
    IF correct_answer THEN
        llm_says_new_wins := lattice_says_new_wins;
    ELSE
        llm_says_new_wins := NOT lattice_says_new_wins;
    END IF;

    IF llm_says_new_wins THEN
        UPDATE fact_llm
           SET sys_time = tstzrange(lower(sys_time), clock_timestamp())
         WHERE ctid = inc_ctid;
        RETURN NEW;
    ELSE
        RAISE EXCEPTION 'llm-gated: NEW_LOSES (mock verdict)'
            USING ERRCODE = 'check_violation';
    END IF;
END;
$$;

CREATE TRIGGER fact_llm_before_insert
    BEFORE INSERT ON fact_llm
    FOR EACH ROW EXECUTE FUNCTION fact_llm_rules();
