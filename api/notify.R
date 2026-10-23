# notify.R ---------------------------------------------------------------------
# Short messages to a Discord channel, through its webhook
# (metacheck_discord_webhook; the playbook writes it to ~/.Renviron as
# DISCORD_WEBHOOK_URL): finished and failed PsyArXiv reports, mistakes readers
# report, and problems the server watch (watch.R) finds. Without the address
# nothing is sent; a message that cannot be sent is only logged, never an error.

notify <- function(text) {
  url <- Sys.getenv("DISCORD_WEBHOOK_URL")
  if (!nzchar(url)) return(invisible(FALSE))
  # Discord takes at most 2000 characters per message
  if (nchar(text) > 1900) text <- paste0(substr(text, 1, 1897), "...")
  ok <- tryCatch({
    resp <- httr2::request(url) |>
      # no @everyone or other mentions, whatever a title or message contains
      httr2::req_body_json(list(content = text, allowed_mentions = list(parse = list()))) |>
      httr2::req_timeout(20) |>
      httr2::req_retry(max_tries = 3) |>
      httr2::req_error(is_error = function(r) FALSE) |>
      httr2::req_perform()
    httr2::resp_status(resp) < 300
  }, error = function(e) FALSE)
  if (!ok) message("Discord message not sent")
  invisible(ok)
}

# The public address of this server's website, for links in messages.
notify_site <- function() sub("/+$", "", Sys.getenv("METACHECK_SITE_URL"))
