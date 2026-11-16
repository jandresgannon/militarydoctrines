# Sync the public corpus from measuring-asi (the single source of truth) into
# this website, then validate it.
#
#   Rscript docs/01_sync-corpus.R            # sync + validate, PDFs reported only
#   Rscript docs/01_sync-corpus.R --pdfs     # also copy missing PDFs into the
#                                            # public Dropbox folder (goes live)
#
# Inputs (read-only):
#   measuring-asi/data/raw/nss_metadata.csv          Google-Sheet snapshot; refresh
#                                                    it with measuring-asi/docs/00_sheets_to_raw.R
#   measuring-asi/inst/extdata/txts/{marker_md,pymupdf,txt}/   full text
#   measuring-asi/inst/extdata/txts/chunking_results_128/      chunked text
#   measuring-asi/inst/extdata/pdfs/                           original PDFs
#   measuring-asi/data/release_manifest.csv          written by measuring-asi/docs/37: the text
#                                                    each document is measured on, its English
#                                                    translation, its sentence file
#   measuring-asi/inst/extdata/affective_salience.csv + CODEBOOK.md   the dyad-year measure
# Outputs:
#   content/data_copy/txt_files/<stem>.txt           one per metadata row
#   content/data_copy/csv_files/<stem>_chunks.csv    one per metadata row
#   content/data_copy/translations/<stem>_en.txt     English machine translation, translated documents
#   content/data_copy/sentences/<stem>_sentences.csv sentence-segmented English text, measured documents
#   content/data_copy/measure/                       the dyad-year measure and its codebook
#   content/data_copy/nss_metadata.csv               public metadata download
#   data/documents.rds                               page-ready index (links, names)
#   data/sync_report.csv                             per-document status of this run

upstream   <- Sys.getenv("MEASURING_ASI", here::here("..", "measuring-asi"))
pdf_public <- Sys.getenv("PDF_PUBLIC_DIR",
                         here::here("..", "00_Archive", "03_Hopper", "data", "doctrines"))
pdf_folder_url <- "https://www.dropbox.com/scl/fo/3ymtsdj56ql27esobmwrz/AD4CNJLKn-fL3__f7qwQ2j8?rlkey=50k5ronmzaoi8l0ek2czwenyw&dl=0"
copy_pdfs  <- "--pdfs" %in% commandArgs(trailingOnly = TRUE)

txts_dir <- file.path(upstream, "inst", "extdata", "txts")
out_txt  <- here::here("content", "data_copy", "txt_files")
out_csv  <- here::here("content", "data_copy", "csv_files")
out_tr   <- here::here("content", "data_copy", "translations")
out_sent <- here::here("content", "data_copy", "sentences")
out_meas <- here::here("content", "data_copy", "measure")
for (d in c(out_txt, out_csv, out_tr, out_sent, out_meas)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
dir.create(here::here("data"), showWarnings = FALSE)

stopifnot(dir.exists(upstream), dir.exists(txts_dir))

# ---- Metadata -------------------------------------------------------------

meta <- readr::read_csv(file.path(upstream, "data", "raw", "nss_metadata.csv"),
                        col_types = readr::cols(.default = "c")) |>
  dplyr::mutate(
    dplyr::across(dplyr::everything(), trimws),
    year = as.integer(year),
    keep = as.integer(keep),
    stem = tools::file_path_sans_ext(file_names)
  )

stopifnot(!anyDuplicated(meta$stem), !anyNA(meta$year), all(meta$keep %in% 0:1))

# Release manifest (measuring-asi/docs/37): one row per metadata row. Paths are relative to
# measuring-asi; empty when a document has no such file.
release <- readr::read_csv(file.path(upstream, "data", "release_manifest.csv"),
                           col_types = readr::cols(.default = "c")) |>
  dplyr::mutate(dplyr::across(c(text_file, translation_file, sentence_file),
                              ~ dplyr::if_else(is.na(.x) | .x == "", NA_character_, file.path(upstream, .x))))
stopifnot(setequal(release$stem, meta$stem))
meta <- dplyr::left_join(meta, dplyr::select(release, stem, measure_status = status, text_file,
                                             translation_file, sentence_file), by = "stem")

# ---- File resolution --------------------------------------------------------
# Upstream filenames drift from the Sheet's file_names in case, accents and the
# _noneng suffix (e.g. LibroBlancodelaDefensa vs LibroBlancoDeLaDefensa,
# germany_1994_WhitePaper vs ..._noneng). Matching runs in three passes over all
# source directories, in priority order: exact name, then case/accent-
# insensitive, then also ignoring _noneng. The last pass never takes a file
# that is another metadata row's own edition (france_2008 English must not pick
# up the French Marker file), and no pass guesses between two candidates.

norm_key <- function(x, drop_lang = FALSE) {
  x <- stringi::stri_trans_general(x, "Latin-ASCII")
  if (drop_lang) x <- sub("_noneng$", "", x)
  tolower(gsub("[^A-Za-z0-9]", "", x))
}

list_stems <- function(dir, suffix) {
  files <- list.files(dir)
  files <- files[endsWith(files, suffix) & !grepl("_mten", files)]  # MT stays out
  stats::setNames(file.path(dir, files), substr(files, 1, nchar(files) - nchar(suffix)))
}

# dirs: named list of directory -> suffix, highest priority first
resolve <- function(stems, dirs) {
  cands <- unlist(unname(Map(list_stems, names(dirs), dirs)))
  own_editions <- norm_key(stems)
  passes <- list(
    function(x) x,
    function(x) norm_key(x),
    function(x) norm_key(x, drop_lang = TRUE)
  )
  out <- rep(NA_character_, length(stems))
  for (p in seq_along(passes)) {
    pool <- cands
    if (p == 3) pool <- pool[!norm_key(names(pool)) %in% own_editions]
    keys <- passes[[p]](names(pool))
    for (i in which(is.na(out))) {
      hit <- pool[keys == passes[[p]](stems[i])]
      if (!length(hit)) next
      hit <- hit[dirname(hit) == dirname(hit)[1]]  # highest-priority directory only
      if (length(hit) == 1) out[i] <- hit
    }
  }
  out
}

# Full text: Marker output where it exists (the chunked text was built from it),
# else pymupdf4llm, else the legacy txt export.
meta$txt_src <- resolve(meta$stem, stats::setNames(
  c(".md", ".md", ".txt"), file.path(txts_dir, c("marker_md", "pymupdf", "txt"))))
# A document in the measure is published with the exact text the measure was computed from
# (for scanned documents that is the fresh Marker OCR, txts/marker_reocr_md).
measured_en <- meta$measure_status == "english" & !is.na(meta$text_file)
meta$txt_src[measured_en] <- meta$text_file[measured_en]
meta$csv_src <- resolve(meta$stem, stats::setNames(
  "_chunks.csv", file.path(txts_dir, "chunking_results_128")))
meta$pdf_src <- resolve(meta$stem, stats::setNames(
  ".pdf", file.path(upstream, "inst", "extdata", "pdfs")))
meta$pdf_pub <- resolve(meta$stem, stats::setNames(".pdf", pdf_public))

# ---- PDFs: report (and optionally publish) what the public folder lacks ------

pdf_missing_public <- meta |> dplyr::filter(is.na(pdf_pub), !is.na(pdf_src))
if (nrow(pdf_missing_public) > 0) {
  if (copy_pdfs) {
    dest <- file.path(pdf_public, basename(pdf_missing_public$pdf_src))
    file.copy(pdf_missing_public$pdf_src, dest, overwrite = FALSE)
    meta$pdf_pub[match(pdf_missing_public$stem, meta$stem)] <- dest
    message("Copied ", length(dest), " PDF(s) into the public folder; rebuild doctrines.zip.")
  } else {
    message("PDFs not yet in the public folder (re-run with --pdfs to publish):\n  ",
            paste(basename(pdf_missing_public$pdf_src), collapse = "\n  "))
  }
}

# ---- Copy text and chunks (only when content changed) ----------------------

sync_file <- function(src, dest) {
  if (is.na(src)) return("missing")
  if (!file.exists(dest)) { file.copy(src, dest); return("added") }
  if (unname(tools::md5sum(src)) == unname(tools::md5sum(dest))) return("unchanged")
  file.copy(src, dest, overwrite = TRUE)
  "updated"
}

meta$txt_file <- paste0(meta$stem, ".txt")
meta$csv_file <- paste0(meta$stem, "_chunks.csv")
meta$txt_status <- mapply(sync_file, meta$txt_src, file.path(out_txt, meta$txt_file))
meta$csv_status <- mapply(sync_file, meta$csv_src, file.path(out_csv, meta$csv_file))
meta$tr_file   <- paste0(meta$stem, "_en.txt")
meta$sent_file <- paste0(meta$stem, "_sentences.csv")
meta$tr_status   <- mapply(sync_file, meta$translation_file, file.path(out_tr, meta$tr_file))
meta$sent_status <- mapply(sync_file, meta$sentence_file, file.path(out_sent, meta$sent_file))
# The dyad-year measure and its codebook.
meas_status <- c(
  sync_file(file.path(upstream, "inst", "extdata", "affective_salience.csv"),
            file.path(out_meas, "nss_dyad_year_measure.csv")),
  sync_file(file.path(upstream, "inst", "extdata", "CODEBOOK.md"), file.path(out_meas, "CODEBOOK.md")))

# Remove files no metadata row points to (old names, dropped documents).
prune <- function(dir, keep_files) {
  orphans <- setdiff(list.files(dir), keep_files)
  file.remove(file.path(dir, orphans))
  orphans
}
orphans <- c(prune(out_txt, meta$txt_file[meta$txt_status != "missing"]),
             prune(out_csv, meta$csv_file[meta$csv_status != "missing"]),
             prune(out_tr, meta$tr_file[meta$tr_status != "missing"]),
             prune(out_sent, meta$sent_file[meta$sent_status != "missing"]))

# ---- Display names and map codes --------------------------------------------

display_names <- c(
  bosnia = "Bosnia and Herzegovina", burkinafaso = "Burkina Faso",
  centralafricanrepublic = "Central African Republic", cookislands = "Cook Islands",
  costarica = "Costa Rica", czechrepublic = "Czech Republic",
  dominicanrepublic = "Dominican Republic", elsalvador = "El Salvador",
  eu = "European Union", guiana = "French Guiana", newzealand = "New Zealand",
  northmacedonia = "North Macedonia", papua = "Papua New Guinea",
  sierraleone = "Sierra Leone", solomonislands = "Solomon Islands",
  southafrica = "South Africa", southkorea = "South Korea",
  timorleste = "Timor-Leste", trinidadandtobago = "Trinidad and Tobago",
  unitedkingdom = "United Kingdom", us = "United States"
)

meta <- meta |>
  dplyr::mutate(
    country = dplyr::coalesce(unname(display_names[country_name]),
                              tools::toTitleCase(country_name)),
    iso3 = suppressWarnings(countrycode::countrycode(
      country, "country.name", "iso3c",
      custom_match = c("European Union" = NA, "French Guiana" = "GUF")
    ))
  )

# ---- Public links ------------------------------------------------------------

meta <- meta |>
  dplyr::mutate(
    pdf_url = dplyr::if_else(
      is.na(pdf_pub), NA_character_,
      paste0(sub("&dl=0$", "", pdf_folder_url), "&preview=",
             vapply(basename(pdf_pub), utils::URLencode, character(1), reserved = TRUE),
             "&dl=0")
    ),
    txt_url = dplyr::if_else(txt_status == "missing", NA_character_,
                             paste0("data_copy/txt_files/", utils::URLencode(txt_file))),
    csv_url = dplyr::if_else(csv_status == "missing", NA_character_,
                             paste0("data_copy/csv_files/", utils::URLencode(csv_file))),
    tr_url = dplyr::if_else(tr_status == "missing", NA_character_,
                            paste0("data_copy/translations/", utils::URLencode(tr_file))),
    sent_url = dplyr::if_else(sent_status == "missing", NA_character_,
                              paste0("data_copy/sentences/", utils::URLencode(sent_file)))
  )

# ---- Write outputs -------------------------------------------------------------

meta |>
  dplyr::select(file_names, country_name, year, title, language, keep, type, measure_status) |>
  readr::write_csv(here::here("content", "data_copy", "nss_metadata.csv"), na = "")

meta |>
  dplyr::select(file_names, stem, country_name, country, iso3, year, title,
                language, keep, type, measure_status, pdf_url, txt_url, csv_url, tr_url, sent_url) |>
  saveRDS(here::here("data", "documents.rds"))

report <- meta |>
  dplyr::transmute(stem, keep, measure_status,
                   pdf = !is.na(pdf_pub), txt_status, csv_status, tr_status, sent_status,
                   txt_source = basename(dirname(txt_src)))
readr::write_csv(report, here::here("data", "sync_report.csv"), na = "")

# Bulk downloads: rebuilt only when a file changed, so the zips do not churn.
build_zip <- function(dir, zipfile, changed) {
  if (file.exists(zipfile) && !changed) return(invisible())
  unlink(zipfile)
  meta_csv <- here::here("content", "data_copy", "nss_metadata.csv")
  withr::with_dir(dir, utils::zip(zipfile, c(list.files(), meta_csv),
                                  flags = "-q -9 -j"))
}
any_change <- function(status) any(status %in% c("added", "updated")) || length(orphans) > 0
build_zip(out_txt, here::here("content", "data_copy", "nss_txt_all.zip"),
          any_change(meta$txt_status))
build_zip(out_csv, here::here("content", "data_copy", "nss_chunks_all.zip"),
          any_change(meta$csv_status))
build_zip(out_tr, here::here("content", "data_copy", "nss_translations_all.zip"),
          any_change(meta$tr_status))
build_zip(out_sent, here::here("content", "data_copy", "nss_sentences_all.zip"),
          any_change(meta$sent_status))

# ---- Validation summary ------------------------------------------------------

# Upstream chunk files with no metadata row. Those with a PDF upstream are real
# documents the Sheet does not list; those without are leftover duplicates
# (pre-_noneng names of documents already in the Sheet) and are only counted.
chunk_stems <- sub("_chunks\\.csv$", "", list.files(file.path(txts_dir, "chunking_results_128")))
chunk_stems <- chunk_stems[!grepl("_mten", chunk_stems)]
unlisted <- chunk_stems[!paste0(chunk_stems, "_chunks.csv") %in% basename(meta$csv_src)]
has_pdf  <- file.exists(file.path(upstream, "inst", "extdata", "pdfs", paste0(unlisted, ".pdf")))
stale_dupes <- unlisted[!has_pdf]
unlisted <- unlisted[has_pdf]

cat("\n== Corpus sync ==\n")
cat(sprintf("Documents: %d (%d keep = 1) from %d countries, %d-%d\n",
            nrow(meta), sum(meta$keep), dplyr::n_distinct(meta$country_name),
            min(meta$year), max(meta$year)))
cat(sprintf("measure: %s documents in English, %s translated, %s not measured; measure file %s, codebook %s\n",
            sum(meta$measure_status == "english"), sum(meta$measure_status == "translated"),
            sum(meta$measure_status == "not_measured"), meas_status[1], meas_status[2]))
for (k in c("txt", "csv", "tr", "sent")) {
  st <- table(factor(meta[[paste0(k, "_status")]],
                     levels = c("added", "updated", "unchanged", "missing")))
  cat(sprintf("%s: %s\n", k, paste(names(st), st, sep = " ", collapse = ", ")))
}
cat(sprintf("pdf: %d linked, %d not in public folder, %d with no PDF upstream\n",
            sum(!is.na(meta$pdf_url)), nrow(pdf_missing_public),
            sum(is.na(meta$pdf_src) & is.na(meta$pdf_pub))))
changed <- meta$stem[meta$txt_status %in% c("added", "updated") |
                     meta$csv_status %in% c("added", "updated")]
if (length(changed)) cat("Added/updated:\n ", paste(changed, collapse = "\n  "), "\n")
missing <- meta$stem[meta$txt_status == "missing" | meta$csv_status == "missing"]
if (length(missing)) cat("Missing text or chunks upstream:\n ", paste(missing, collapse = "\n  "), "\n")
if (length(orphans)) cat("Removed", length(orphans), "orphaned file(s)\n")
if (length(unlisted)) cat("Upstream documents with no metadata row (add to the Sheet):\n ",
                          paste(unlisted, collapse = "\n  "), "\n")
if (length(stale_dupes)) cat(length(stale_dupes),
                             "leftover upstream chunk file(s) with no PDF or metadata row ignored\n")
