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
   bash docs/02_publish.sh
   ```

   Freeze is off, so every render re-reads the data. Preview locally first: `.claude/launch.json` serves `_site/` on port 8765.
   Do not use `quarto publish gh-pages` here: its temporary checkout sits inside Dropbox, where git refuses to delete old files, so removed pages stay online. `docs/02_publish.sh` builds the commit outside Dropbox and mirrors `_site/` exactly. If a GitHub Pages deploy hangs in "queued", request a fresh build with `gh api -X POST repos/jandresgannon/militarydoctrines/pages/builds`.

## Large files

`content/data_copy/txt_files/`, `csv_files/` and the `*.zip` bulk downloads (about 500 MB) are gitignored on `main`. Step 2 regenerates them, and `docs/02_publish.sh` commits them to `gh-pages`.

## DOI (Harvard Dataverse)

`Rscript docs/03_dataverse-package.R <version>` builds a release in `~/militarydoctrines-dataverse/<version>/`. It sits outside Dropbox because it is about 9.5 GB. The release contains:

- `upload/`: the files to upload
  - the metadata
  - a single full-text table
  - zips of the texts, the chunks, and the PDFs (in parts under Dataverse's 2.5 GB per-file limit)
  - a README with the codebook
- `FORM_FIELDS.md`: suggested Dataverse metadata
- `UPLOAD_NOTES.md`: upload steps, including why each zip is wrapped in another zip

Run `docs/01_sync-corpus.R` first. After the dataset is published, add the DOI to `content/_citation.md`.
