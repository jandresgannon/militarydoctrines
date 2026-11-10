# Military Doctrines

Code and content for <https://militarydoctrines.com>, a Quarto website published to the `gh-pages` branch.

## Source of truth

Everything the site serves comes from the `measuring-asi` repository (expected next to this one):

| What | Where in measuring-asi |
|---|---|
| Document metadata | `data/raw/nss_metadata.csv`, a snapshot of the Google Sheet made by `docs/00_sheets_to_raw.R` |
| Full text | `inst/extdata/txts/marker_md/` (preferred), else `txts/pymupdf/`, else `txts/txt/` |
| Chunked text | `inst/extdata/txts/chunking_results_128/` |
| PDFs | `inst/extdata/pdfs/` |

PDFs are too large for GitHub Pages. The site links to them in the shared Dropbox folder `00_Archive/03_Hopper/data/doctrines/`, with a 10 GB `doctrines.zip` next to it.

## Updating the site

1. **Update upstream.** Add or edit rows in the Google Sheet, then in measuring-asi run `docs/00_sheets_to_raw.R` and produce the PDF, text and chunk files there. A document appears on the site only if it has a row in the Sheet.
2. **Sync.** From this repo, run `Rscript docs/01_sync-corpus.R`. It copies changed text and chunk files into `content/data_copy/`, removes files with no metadata row, rebuilds the bulk zips, writes `data/documents.rds` (which the pages read) and `data/sync_report.csv`, and prints:
   - what was added or updated,
   - documents missing text or chunks,
   - upstream files that have no metadata row (add those to the Sheet),
   - PDFs missing from the public Dropbox folder.
3. **Publish new PDFs.** Run `Rscript docs/01_sync-corpus.R --pdfs` to copy missing PDFs into the public Dropbox folder, then rebuild `doctrines.zip`.
4. **Changelog.** Add an entry to `content/changelog.qmd` and bump the version in `content/_citation.md`.
5. **Render and publish.**

   ```bash
   quarto render
   quarto publish gh-pages
   ```

   Freeze is off, so every render re-reads the data. Preview locally first: `.claude/launch.json` serves `_site/` on port 8765.

## Large files

`content/data_copy/txt_files/`, `csv_files/` and the `*.zip` bulk downloads (about 500 MB) are gitignored on `main`. Step 2 regenerates them, and `quarto publish` commits them to `gh-pages`.

## DOI

The dataset citation has no DOI yet. To add one, deposit a release on Zenodo (metadata CSV, the two zips, the PDF zip and the codebook), then add the DOI to `content/_citation.md`.
