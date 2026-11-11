# Package a versioned release of the corpus for Harvard Dataverse.
#
#   Rscript docs/01_sync-corpus.R                  # make sure the site data is current
#   Rscript docs/03_dataverse-package.R 2026.11    # version = changelog / citation version
#
# Output goes OUTSIDE Dropbox (about 9.5 GB, which would otherwise sync):
#   ~/militarydoctrines-dataverse/<version>/upload/   exactly the files to upload
#
# Every file in upload/ uses the metadata stem, so the PDF, text and chunked
# text of a document always share a name. Zips are NOT double-wrapped: Harvard
# Dataverse's uploader sends files straight to storage and stores zips as-is
# (verified on release 2026.11, whose wrapped zips were published wrapped).

args    <- commandArgs(trailingOnly = TRUE)
version <- if (length(args)) args[1] else stop("Give the release version, e.g. 2026.11")
out_root <- Sys.getenv("DATAVERSE_OUT", file.path(Sys.getenv("HOME"), "militarydoctrines-dataverse"))
pdf_public <- Sys.getenv("PDF_PUBLIC_DIR",
                         here::here("..", "00_Archive", "03_Hopper", "data", "doctrines"))
doi      <- Sys.getenv("DATAVERSE_DOI", "https://doi.org/10.7910/DVN/OHOMP8")
max_part <- 2.3e9                     # Harvard Dataverse web upload limit is 2.5 GB/file

out    <- file.path(out_root, version)
upload <- file.path(out, "upload")
if (dir.exists(out)) stop(out, " already exists; remove it or choose another version")
dir.create(upload, recursive = TRUE)
stage <- file.path(tempdir(), "dv")
dir.create(stage)

docs <- readRDS(here::here("data", "documents.rds"))
data_copy <- here::here("content", "data_copy")

# Move a finished zip into upload/.
wrap_zip <- function(inner, dest) {   # tempdir may be on another filesystem
  stopifnot(file.copy(inner, dest)); unlink(inner)
}

# ---- Metadata ------------------------------------------------------------------

invisible(file.copy(file.path(data_copy, "nss_metadata.csv"), file.path(upload, "nss_metadata.csv")))

# ---- Full text: one table, one row per document ----------------------------------

txt_path <- file.path(data_copy, "txt_files", paste0(docs$stem, ".txt"))
fulltext <- docs |>
  dplyr::transmute(file_names, country_name, year, title, language, keep, type,
                   text = ifelse(file.exists(txt_path),
                                 vapply(txt_path, function(f) if (file.exists(f))
                                   paste(readLines(f, warn = FALSE, encoding = "UTF-8"),
                                         collapse = "\n") else NA_character_,
                                   character(1)),
                                 NA_character_))
readr::write_csv(fulltext, gzfile(file.path(upload, "nss_fulltext.csv.gz")), na = "")

# ---- Text and chunk zips (same files as the website's bulk downloads) ------------

for (z in c("nss_txt_all.zip", "nss_chunks_all.zip")) {
  invisible(file.copy(file.path(data_copy, z), file.path(stage, z)))
  wrap_zip(file.path(stage, z), file.path(upload, z))
}

# ---- PDFs: split into parts under the upload limit, never splitting a country -----

pdf_name <- ifelse(is.na(docs$pdf_url), NA_character_,
                   utils::URLdecode(sub("&dl=0$", "", sub(".*&preview=", "", docs$pdf_url))))
pdfs <- docs |>
  dplyr::mutate(src = file.path(pdf_public, pdf_name)) |>
  dplyr::filter(!is.na(pdf_name)) |>
  dplyr::mutate(bytes = file.size(src), dest = paste0(stem, ".pdf")) |>
  dplyr::arrange(country_name, year, stem)
stopifnot(all(file.exists(pdfs$src)))

by_country <- pdfs |>
  dplyr::group_by(country_name) |>
  dplyr::summarise(bytes = sum(bytes), .groups = "drop")
part <- integer(nrow(by_country)); p <- 1L; acc <- 0
for (i in seq_len(nrow(by_country))) {
  if (acc > 0 && acc + by_country$bytes[i] > max_part) { p <- p + 1L; acc <- 0 }
  part[i] <- p; acc <- acc + by_country$bytes[i]
}
if (any(by_country$bytes > max_part)) stop("A single country exceeds the part size limit")
pdfs$part <- part[match(pdfs$country_name, by_country$country_name)]

pdf_parts <- character(0)
for (k in sort(unique(pdfs$part))) {
  rows <- pdfs[pdfs$part == k, ]
  name <- sprintf("nss_pdfs_%02d_%s-%s.zip", k, rows$country_name[1], rows$country_name[nrow(rows)])
  dir <- file.path(stage, "pdfs")
  unlink(dir, recursive = TRUE); dir.create(dir)
  file.symlink(normalizePath(rows$src), file.path(dir, rows$dest))   # renamed to the stem
  withr::with_dir(stage, utils::zip(file.path(stage, name), "pdfs", flags = "-q -r -0"))
  wrap_zip(file.path(stage, name), file.path(upload, name))
  pdf_parts <- c(pdf_parts, sprintf("| `%s` | %d PDFs, %s to %s (%.1f GB) |", name, nrow(rows),
                                    unique(rows$country_name)[1],
                                    tail(unique(rows$country_name), 1), sum(rows$bytes) / 1e9))
}

# ---- README (uploaded with the data) ------------------------------------------------

n_docs <- nrow(docs); n_core <- sum(docs$keep); n_iss <- dplyr::n_distinct(docs$country_name)
yrs <- range(docs$year)
codebook <- readLines(here::here("content", "codebook.qmd"))
codebook <- codebook[(which(codebook == "## File naming")):(which(codebook == "## All texts in one table") - 1)]

readme <- c(
  sprintf("# Military Doctrines: A Corpus of National Security Strategy Documents (version %s)", version),
  "",
  sprintf("A catalog of %d national security strategies, defense white papers, military doctrines, and related strategy documents issued by %d countries, territories, and organizations from %d to %d, with the original PDFs, extracted full text, and chunked text for text-as-data research. %d documents form the core corpus (`keep = 1`); the rest are catalogued documents outside that scope.",
          n_docs, n_iss, yrs[1], yrs[2], n_core),
  "",
  "Project website: <https://militarydoctrines.com>, which has a searchable table of every document, and a changelog.",
  "",
  "## Files",
  "",
  "| File | Contents |",
  "|---|---|",
  "| `README.md` | This file: description and codebook. |",
  sprintf("| `nss_metadata.csv` | One row per document (%d rows). |", n_docs),
  "| `nss_fulltext.csv.gz` | The metadata plus a `text` column holding each document's full extracted text: the whole corpus in one table. |",
  "| `nss_txt_all.zip` | One `.txt` file per document, plus the metadata. |",
  "| `nss_chunks_all.zip` | One `_chunks.csv` file per document, plus the metadata. |",
  pdf_parts,
  "",
  sprintf("PDFs are split into several zips to stay under the repository's per-file size limit; each country's documents are in a single zip. %d documents have no PDF in this release.",
          sum(is.na(docs$pdf_url))),
  "",
  codebook,
  "## Copyright of the original documents",
  "",
  "The PDFs are official publications of the issuing governments and remain subject to their terms. They are redistributed here for research use. The metadata, extracted text, and chunked text are released under the license shown on this dataset.",
  "",
  "## Citation",
  "",
  sprintf("Gannon, J Andrés. 2026. *Military Doctrines: A Corpus of National Security Strategy Documents*. Version %s. Harvard Dataverse. %s", version, doi),
  "",
  "Gannon, J Andrés. \"A Text-as-Data Approach to Measuring Interstate Relations Using National Security Strategies.\" Working paper.",
  ""
)
writeLines(readme, file.path(upload, "README.md"))

# ---- Manifest with checksums ----------------------------------------------------------

files <- list.files(upload, full.names = TRUE)
manifest <- data.frame(file = basename(files), bytes = file.size(files),
                       md5 = unname(tools::md5sum(files)))
readr::write_csv(manifest, file.path(out, "MANIFEST.csv"))

unlink(stage, recursive = TRUE)
cat(sprintf("\nRelease %s written to %s\n", version, out))
print(transform(manifest[, 1:2], GB = round(bytes / 1e9, 2))[, c("file", "GB")], row.names = FALSE)
