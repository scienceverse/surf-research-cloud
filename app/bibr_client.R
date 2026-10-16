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
#' @return path to the JSON file, readable with metacheck::read().
bibr_convert <- function(pdf_path, save_dir,
                         api_url = Sys.getenv("BIBR_API_URL"),
                         api_key = Sys.getenv("BIBR_API_KEY"),
                         timeout = 900) {
  req <- httr2::request(api_url) |>
    httr2::req_url_path_append("papers", "extract") |>
    httr2::req_body_multipart(file = curl::form_file(pdf_path)) |>
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

  # Saved exactly as bibr sent it.
  dir.create(save_dir, showWarnings = FALSE, recursive = TRUE)
  json_path <- file.path(save_dir,
                         sub("\\.[^.]*$", ".json", basename(pdf_path)))
  writeBin(httr2::resp_body_raw(resp), json_path)
  json_path
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
