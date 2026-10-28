# SPIKE relay: passes requests in the OpenAI format on to TU/e's SPIKE
# language-model gateway, for a server outside the TU/e network (the SURF
# metacheck server, metacheck_llm_first_url), and sends SPIKE's answer back
# unchanged. Runs on TU/e's Shiny server, not on SURF (see "The SPIKE relay"
# in the README).
#
# https://shiny.ieis.tue.nl/spike_relay/chat/completions
#   -> SPIKE_GATEWAY/chat/completions
#
# The caller must send "Authorization: Bearer <RELAY_KEY>"; the relay replaces
# it with the SPIKE key. Settings in .Renviron next to this file:
#   RELAY_KEY      secret shared with the caller (required)
#   SPIKE_API_KEY  key for the SPIKE gateway (required)
#   SPIKE_GATEWAY  optional, default below
#
# It uses Shiny's page function as a plain web address: with uiPattern = ".*"
# it answers on every path under the app, and the attribute
# http_methods_supported lets it accept POST. Nothing is stored or logged.
library(shiny)

gateway <- sub("/+$", "", Sys.getenv("SPIKE_GATEWAY",
  "https://spike-gateway-runai-aiteam.inference.spike.tue.nl/v1"))

reply <- function(status, text) {
  httpResponse(status, "application/json",
               jsonlite::toJSON(list(error = list(message = text)), auto_unbox = TRUE))
}

ui <- function(req) {
  relay_key <- Sys.getenv("RELAY_KEY")
  spike_key <- Sys.getenv("SPIKE_API_KEY")
  path <- req$PATH_INFO %||% "/"
  if (identical(req$REQUEST_METHOD, "GET") && path %in% c("", "/")) {
    return(httpResponse(200, "text/plain", "SPIKE relay is running.\n"))
  }
  if (!nzchar(relay_key) || !nzchar(spike_key)) return(reply(503, "relay is not set up"))
  if (!identical(req$HTTP_AUTHORIZATION, paste("Bearer", relay_key))) {
    return(reply(401, "wrong or missing key"))
  }
  body <- if (identical(req$REQUEST_METHOD, "POST")) req$rook.input$read() else NULL
  # "X-Relay-Wait: no": send a small request on by itself and answer at once
  # (202), for a request whose answer nobody waits for, such as the one that
  # makes SPIKE load a model (SPIKE answers it with an error after about 45 s).
  # This app answers one request at a time, so otherwise all others would wait.
  # The SPIKE key goes to curl on its standard input (written by the shell's
  # own printf), not on its command line, which other users can see.
  if (identical(tolower(req$HTTP_X_RELAY_WAIT %||% ""), "no") &&
      length(body) && length(body) < 10000) {
    Sys.setenv(RELAY_BODY = rawToChar(body), RELAY_URL = paste0(gateway, path))
    system(paste('printf \'header = "Authorization: Bearer %s"\\n\' "$SPIKE_API_KEY" |',
                 'curl -s -K - -o /dev/null -m 120 -H "Content-Type: application/json"',
                 '-d "$RELAY_BODY" "$RELAY_URL"'), wait = FALSE)
    Sys.unsetenv(c("RELAY_BODY", "RELAY_URL"))
    return(httpResponse(202, "application/json", '{"status":"sent on"}'))
  }
  r <- httr2::request(paste0(gateway, path)) |>
    httr2::req_method(req$REQUEST_METHOD) |>
    httr2::req_headers(Authorization = paste("Bearer", spike_key)) |>
    httr2::req_timeout(600) |>
    httr2::req_error(is_error = function(resp) FALSE)
  if (length(body)) r <- httr2::req_body_raw(r, body, type = "application/json")
  resp <- tryCatch(httr2::req_perform(r), error = function(e) e)
  if (inherits(resp, "error")) return(reply(502, paste("SPIKE did not answer:", conditionMessage(resp))))
  httpResponse(httr2::resp_status(resp),
               httr2::resp_header(resp, "content-type") %||% "application/json",
               rawToChar(httr2::resp_body_raw(resp)))
}
attr(ui, "http_methods_supported") <- c("GET", "POST")

shinyApp(ui, function(input, output, session) NULL, uiPattern = ".*")
