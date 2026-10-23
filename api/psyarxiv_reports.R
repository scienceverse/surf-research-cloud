# psyarxiv_reports.R ---------------------------------------------------------
# PsyArXiv reports (prototype): metacheck's checklist report for the newest
# PsyArXiv preprints, made in advance by psyarxiv-reports-generate.R (run by
# metacheck-psyarxiv-reports.timer) into PSYARXIV_REPORTS_DIR:
#   reports/<id>.html   the report (served by nginx at /psyarxiv-reports-files/)
#   reports/<id>.json   the preprint's details (title, version, ...)
#   feedback/*.json     "the report contains mistakes" messages from readers
#   deleted/<id>.json   reports deleted through a delete link (never made again)
# Sourced by api.R, which has the endpoints (/psyarxiv-reports/...). The page
# is site/psyarxiv-reports/.
#
# A reader's message is saved and, when mail is set up (SMTP_URL, MAIL_TO),
# mailed with the report attached and a button that opens the delete page. A
# delete link carries a key: an HMAC of the preprint id with
# PSYARXIV_REPORTS_SECRET, so only links from those mails can delete.

PR_DIR <- Sys.getenv("PSYARXIV_REPORTS_DIR")
PR_SECRET <- Sys.getenv("PSYARXIV_REPORTS_SECRET")
PR_MAX_FEEDBACK_PER_HOUR <- 5L            # per visitor
.pr_feedback_log <- new.env()

.pr_on <- function() nzchar(PR_DIR) && dir.exists(file.path(PR_DIR, "reports"))
.pr_valid_id <- function(id) is.character(id) && length(id) == 1 && grepl("^[a-z0-9]{5,12}$", id)
.pr_key <- function(x) if (nzchar(PR_SECRET)) digest::hmac(PR_SECRET, x, "sha256") else NA_character_
.pr_key_ok <- function(x, key) {
  nzchar(PR_SECRET) && is.character(key) && length(key) == 1 && identical(key, .pr_key(x))
}

.pr_meta <- function(id) {
  if (!.pr_on() || !.pr_valid_id(id)) return(NULL)
  f <- file.path(PR_DIR, "reports", paste0(id, ".json"))
  if (file.exists(f) && file.exists(sub("json$", "html", f))) jsonlite::read_json(f) else NULL
}

.pr_list <- function() {
  if (!.pr_on()) return(list())
  metas <- lapply(list.files(file.path(PR_DIR, "reports"), "\\.json$", full.names = TRUE),
                  function(f) tryCatch(jsonlite::read_json(f), error = function(e) NULL))
  metas <- Filter(Negate(is.null), metas)
  metas[order(vapply(metas, function(m) m$posted %||% "", ""), decreasing = TRUE)]
}

# The address readers reach this server at, from the request nginx passed on
# (for the links in the mail).
.pr_base_url <- function(req) {
  proto <- req$HTTP_X_FORWARDED_PROTO %||% "https"
  host <- req$HTTP_HOST %||% "localhost"
  paste0(proto, "://", host)
}

.pr_mail <- function(fb, meta, base) {
  smtp <- Sys.getenv("SMTP_URL"); to <- Sys.getenv("MAIL_TO")
  if (!nzchar(smtp) || !nzchar(to)) return(FALSE)
  from <- Sys.getenv("MAIL_FROM", paste0("metacheck@", sub("^https?://", "", base)))
  esc <- function(x) htmltools::htmlEscape(x %||% "")
  page <- paste0(base, "/psyarxiv-reports/?id=", meta$id)
  del <- paste0(base, "/psyarxiv-reports/?delete=", meta$id, "&key=", .pr_key(meta$id))
  html <- sprintf(paste0(
    "<p>A reader says the metacheck report on <b>%s</b> (PsyArXiv <a href='%s'>%s</a>, version %s) contains mistakes.</p>",
    "<p><b>Their message:</b><br>%s</p><p><b>Their email address:</b> %s</p>",
    "<p>The report is attached, and online at <a href='%s'>%s</a>.</p>",
    "<p><a href='%s' style='display:inline-block;padding:10px 18px;background:#9B2C1F;color:#ffffff;text-decoration:none;border-radius:6px;font-weight:bold'>Delete this report</a></p>",
    "<p style='color:#666666;font-size:12px'>The button opens a page that asks you to confirm. Sent by the PsyArXiv reports prototype on %s.</p>"),
    esc(meta$title), esc(meta$url), esc(meta$id), esc(meta$version),
    gsub("\n", "<br>", esc(if (nzchar(fb$message)) fb$message else "(no message)")),
    esc(if (nzchar(fb$email)) fb$email else "(not given)"),
    esc(page), esc(page), esc(del), esc(base))
  boundary <- paste0("mc", digest::digest(paste(Sys.time(), meta$id), algo = "md5", serialize = FALSE))
  attach <- gsub("(.{76})", "\\1\r\n", base64enc::base64encode(file.path(PR_DIR, "reports", paste0(meta$id, ".html"))))
  msg <- paste0(
    "From: ", from, "\r\nTo: ", to, "\r\n",
    "Subject: Mistake reported in the metacheck report on PsyArXiv ", meta$id, "\r\n",
    "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"", boundary, "\"\r\n\r\n",
    "--", boundary, "\r\nContent-Type: text/html; charset=utf-8\r\n\r\n", html, "\r\n",
    "--", boundary, "\r\nContent-Type: text/html; name=\"", meta$id, "_metacheck_report.html\"\r\n",
    "Content-Disposition: attachment; filename=\"", meta$id, "_metacheck_report.html\"\r\n",
    "Content-Transfer-Encoding: base64\r\n\r\n", attach, "\r\n--", boundary, "--\r\n")
  curl::send_mail(mail_from = from, mail_rcpt = to, message = msg, smtp_server = smtp,
                  username = Sys.getenv("SMTP_USER"), password = Sys.getenv("SMTP_PASSWORD"),
                  use_ssl = "force", verbose = FALSE)
  TRUE
}

# Saves a reader's message (and mails it); returns whether it was mailed.
.pr_feedback <- function(id, message, email, req) {
  meta <- .pr_meta(id)
  if (is.null(meta)) stop("There is no report for this preprint.", call. = FALSE)
  visitor <- .visitor_code(req)
  recent <- Filter(function(t) difftime(Sys.time(), t, units = "hours") < 1, .pr_feedback_log[[visitor]] %||% list())
  if (length(recent) >= PR_MAX_FEEDBACK_PER_HOUR) stop("Thank you; we have received your messages.", call. = FALSE)
  .pr_feedback_log[[visitor]] <- c(recent, list(Sys.time()))
  fb <- list(id = id, version = meta$version, title = meta$title,
             message = substr(trimws(message %||% ""), 1, 5000),
             email = substr(trimws(email %||% ""), 1, 200),
             time = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"), visitor = visitor)
  fb$mailed <- tryCatch(.pr_mail(fb, meta, .pr_base_url(req)), error = function(e) {
    message("psyarxiv report mail not sent: ", conditionMessage(e)); FALSE })
  f <- file.path(PR_DIR, "feedback", sprintf("%s_%s_%s.json", format(Sys.time(), "%Y%m%d-%H%M%S"), id,
                                             substr(digest::digest(runif(1)), 1, 6)))
  jsonlite::write_json(fb, f, auto_unbox = TRUE, pretty = TRUE)
  # to Discord too (notify.R), without the reader's e-mail address
  notify(sprintf("A reader reported a mistake in the PsyArXiv report on **%s** (%s, version %s):\n%s\n%s/psyarxiv-reports/?id=%s",
                 gsub("[*_`~|]", "", fb$title %||% id), id, fb$version %||% "?",
                 substr(fb$message, 1, 1200), notify_site(), id))
  fb$mailed
}

.pr_delete <- function(id, key) {
  if (!.pr_key_ok(id, key)) stop("This delete link is not valid.", call. = FALSE)
  meta <- .pr_meta(id)
  if (is.null(meta)) stop("There is no report for this preprint (any more).", call. = FALSE)
  jsonlite::write_json(c(meta, list(deleted = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"))),
                       file.path(PR_DIR, "deleted", paste0(id, ".json")), auto_unbox = TRUE, pretty = TRUE)
  unlink(file.path(PR_DIR, "reports", paste0(id, c(".html", ".json"))))
  meta
}
