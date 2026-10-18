## bibr_client.R -------------------------------------------------------------
## Converts a PDF with the bibr server running on this workspace.
##
## The app calls bibr directly instead of through metacheck::convert(), so it
## works with metacheck versions that still have these bugs:
##   * convert(method = "bibr") fails before reaching bibr (metacheck #489)
##   * no bearer token is sent to a self-hosted bibr (metacheck #490)
## Both are fixed in metacheck pull request #496. Once that is in the
## installed metacheck, this file can be replaced by
## metacheck::convert(method = "bibr", backend = "selfhosted").

#' Convert a PDF with a self-hosted bibr server
#'
#' @param pdf_path path to the PDF.
#' @param save_dir directory to write the JSON file to.
#' @param api_url bibr server address (BIBR_API_URL).
#' @param api_key bearer token (BIBR_API_KEY); none is sent when empty.
#' @param timeout seconds to wait for the extraction.
#' @param crossref TRUE or FALSE: whether bibr completes the references
#'   through Crossref (which sends the reference list to Crossref); NULL
#'   leaves it to the bibr server's own setting (CROSSREF_ENRICH).
#' @param file_name the PDF's own name, written into the JSON
#'   (source.file_name). bibr writes the name of the file it was sent, and
#'   uploads are saved under another name (input.pdf by the API, a temporary
#'   name such as 0.pdf by Shiny).
#' @return path to the JSON file, readable with metacheck::read().
bibr_convert <- function(pdf_path, save_dir,
                         api_url = Sys.getenv("BIBR_API_URL"),
                         api_key = Sys.getenv("BIBR_API_KEY"),
                         timeout = 900, crossref = NULL,
                         file_name = basename(pdf_path)) {
  fields <- list(file = curl::form_file(pdf_path))
  if (!is.null(crossref)) fields$crossref <- if (isTRUE(crossref)) "true" else "false"
  req <- httr2::request(api_url) |>
    httr2::req_url_path_append("papers", "extract") |>
    httr2::req_body_multipart(!!!fields) |>
    httr2::req_timeout(timeout) |>
    httr2::req_error(is_error = function(resp) FALSE)
  if (nzchar(api_key)) req <- httr2::req_auth_bearer_token(req, api_key)

  resp <- tryCatch(httr2::req_perform(req), error = function(e) {
    stop("Connection to the bibr server failed (", conditionMessage(e), ")",
         call. = FALSE)
  })
  if (httr2::resp_status(resp) != 200) {
    detail <- tryCatch({
      d <- httr2::resp_body_json(resp)$detail
      if (is.list(d)) d$message %||% "" else as.character(d)
    }, error = function(e) "")
    stop("The bibr server could not convert the PDF (HTTP ",
         httr2::resp_status(resp), "). ", detail, call. = FALSE)
  }

  # Saved as bibr sent it, with the PDF's own name in place of the name of
  # the file bibr was sent.
  dir.create(save_dir, showWarnings = FALSE, recursive = TRUE)
  json_path <- file.path(save_dir,
                         sub("\\.[^.]*$", ".json", basename(pdf_path)))
  writeBin(bibr_set_file_name(httr2::resp_body_raw(resp), basename(pdf_path), file_name),
           json_path)
  json_path
}

#' Put a file's own name into bibr's JSON
#'
#' bibr writes the name of the file it converted as "file_name" (in "source"),
#' once. The text is changed in place, not read and written again, so the rest
#' of the JSON stays exactly as bibr sent it.
#'
#' @param raw the JSON as bytes.
#' @param sent the name of the file bibr was sent.
#' @param name the file's own name.
#' @return the JSON as bytes.
bibr_set_file_name <- function(raw, sent, name) {
  if (is.null(name) || is.na(name) || !nzchar(name) || identical(name, sent)) return(raw)
  json <- rawToChar(raw)
  from <- paste0("\"file_name\":", jsonlite::toJSON(sent, auto_unbox = TRUE))
  to <- paste0("\"file_name\":", jsonlite::toJSON(enc2utf8(name), auto_unbox = TRUE))
  charToRaw(sub(from, to, json, fixed = TRUE, useBytes = TRUE))
}

#' Read a bibr JSON file into a metacheck paper
#'
#' metacheck::read(), plus the paper details (title, DOI, journal, ...) for
#' metacheck versions that do not yet read bibr schema 11 and later, where they
#' are stored under "metadata" instead of "info". metacheck dev reads them
#' itself (since metacheck #467); then this returns read()'s result unchanged.
#' The fallback info table is built the way metacheck's .read_bibr() builds it.
bibr_read <- function(json_path) {
  paper <- metacheck::read(json_path)
  has_title <- !is.null(paper$info$title) && !all(is.na(paper$info$title))
  if (has_title) return(paper)

  data <- jsonlite::read_json(json_path, simplifyVector = TRUE,
                              simplifyDataFrame = TRUE)
  info <- data$metadata
  if (is.null(info)) return(paper)
  keywords <- info$keywords
  info$keywords <- NA
  zeros <- vapply(info, length, integer(1)) == 0
  info[zeros] <- NA
  info <- as.data.frame(info)
  info$keywords <- I(list(keywords))
  info$abstract <- NULL  # as in metacheck's reader
  paper$info <- info
  paper
}

#' Is the bibr server on this workspace ready?
bibr_ready <- function(api_url = Sys.getenv("BIBR_API_URL")) {
  if (!nzchar(api_url)) return(FALSE)
  resp <- tryCatch(
    httr2::request(api_url) |>
      httr2::req_url_path_append("ready") |>
      httr2::req_timeout(5) |>
      httr2::req_error(is_error = function(resp) FALSE) |>
      httr2::req_perform(),
    error = function(e) NULL)
  !is.null(resp) && httr2::resp_status(resp) == 200
}
