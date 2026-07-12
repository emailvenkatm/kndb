CREATE EXTENSION IF NOT EXISTS epistemic;
-- Both isolation levels should load the module cleanly (no runtime exposure
-- of the wrappers at SQL level yet since Agent A hasn't shipped the AM);
-- just verify the extension is present.
SELECT extname FROM pg_extension WHERE extname = 'epistemic';
