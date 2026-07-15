# Build the PVLDB paper.
#
# Prefers `tectonic` (single command, auto-fetches TeX Live packages) but
# falls back to a classic pdflatex + bibtex loop if only that is present.
#
# Usage:
#   make            -> build main.pdf
#   make clean      -> remove build artefacts
#   make distclean  -> also remove main.pdf

PAPER = main

TECTONIC := $(shell command -v tectonic 2>/dev/null)
PDFLATEX := $(shell command -v pdflatex 2>/dev/null)
BIBTEX   := $(shell command -v bibtex   2>/dev/null)

.PHONY: all clean distclean

all: $(PAPER).pdf

ifeq ($(strip $(TECTONIC)),)
# fallback: classic pdflatex + bibtex loop
$(PAPER).pdf: $(PAPER).tex refs.bib
	$(PDFLATEX) -interaction=nonstopmode -halt-on-error $(PAPER).tex
	$(BIBTEX) $(PAPER) || true
	$(PDFLATEX) -interaction=nonstopmode -halt-on-error $(PAPER).tex
	$(PDFLATEX) -interaction=nonstopmode -halt-on-error $(PAPER).tex
else
# preferred: tectonic
$(PAPER).pdf: $(PAPER).tex refs.bib
	tectonic -X compile $(PAPER).tex
endif

clean:
	rm -f $(PAPER).aux $(PAPER).log $(PAPER).bbl $(PAPER).blg \
	      $(PAPER).out $(PAPER).toc $(PAPER).fls $(PAPER).fdb_latexmk \
	      $(PAPER).synctex.gz $(PAPER).nav $(PAPER).snm $(PAPER).vrb

distclean: clean
	rm -f $(PAPER).pdf
