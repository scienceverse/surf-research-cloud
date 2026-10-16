## shiny_progress.R ---------------------------------------------------------
## Show metacheck's own progress messages in this app's progress bar.
##
## metacheck reports progress through one internal helper, pb(), which draws a
## console progress bar (via the progress package). In a Shiny app nobody sees
## the console, so a long download (e.g. an OSF project listed and fetched one
## file at a time) looks frozen. use_shiny_progress() replaces pb() with
## shiny_pb(), which sends every update to the Shiny progress bar instead. The
## replacement lives only in THIS app's R process: the installed package is
## not changed, and nothing else on the server is affected.
##
## shiny_pb() must keep pb()'s interface -- an object with tick(len, tokens),
## message(msg) and terminate() -- and its format tokens (:what, :current,
## :total, ...). If pb() ever changes in metacheck, change this file to match.
##
## When the report runs in a separate R process (see background_job.R) there
## is no Shiny session to send updates to. The "shiny_progress_file" option is
## then set, and each update is written to that file instead, for the app's
## own process to read and show.
##
## Kept identical in every app folder that uses it (like render_report.R).

.shiny_pb <- new.env()
.shiny_pb$modules   <- character(0)  # module names, in run order
.shiny_pb$labels    <- character(0)  # readable label per module
.shiny_pb$range     <- c(0, 1)       # part of the bar the modules fill
.shiny_pb$module    <- 0L            # index of the module running now
.shiny_pb$value     <- 0             # furthest point the bar has reached
.shiny_pb$detail    <- ""            # the line shown under the bar now
.shiny_pb$last_sent <- 0             # time of the last update sent

#' Replace metacheck's pb() with shiny_pb() in this R process
use_shiny_progress <- function() {
  utils::assignInNamespace("pb", shiny_pb, ns = "metacheck")
  invisible(TRUE)
}

#' Tell shiny_pb() which modules are about to run
#'
#' @param modules named character vector: names are module names in run order,
#'   values the label shown while that module runs.
#' @param from,to the part of the progress bar (0-1) the modules fill.
shiny_progress_modules <- function(modules, from = 0, to = 1) {
  .shiny_pb$modules <- names(modules)
  .shiny_pb$labels  <- unname(modules)
  .shiny_pb$range   <- c(from, to)
  .shiny_pb$module  <- 0L
  .shiny_pb$value   <- from
  invisible(TRUE)
}

#' Report one of the app's own steps (e.g. "Converting PDF...")
#'
#' @param value where the bar should be (0-1), or NULL to leave it.
#' @param detail the line shown under the bar.
progress_step <- function(value = NULL, detail = NULL) {
  .shiny_pb_send(value = value, detail = detail, force = TRUE)
}

# Send one update to the progress bar: to the Shiny session, or to the
# progress file when running as a background job. Quietly does nothing
# outside a withProgress() call (e.g. when a module runs at app start-up).
.shiny_pb_send <- function(value = NULL, detail = NULL, force = FALSE) {
  now <- as.numeric(Sys.time())
  # Downloads can tick many times a second; one update every 0.2 s is enough
  # to read and keeps the browser connection quiet.
  if (!force && now - .shiny_pb$last_sent < 0.2) return(invisible())
  .shiny_pb$last_sent <- now
  # Several bars run one after another inside one module, each counting from
  # zero, so the bar only ever moves forward.
  if (!is.null(value)) {
    value <- max(value, .shiny_pb$value)
    .shiny_pb$value <- value
  }
  if (!is.null(detail)) .shiny_pb$detail <- detail

  progress_file <- getOption("shiny_progress_file", "")
  if (nzchar(progress_file)) {
    # One line, replaced on each update: written to a side file first and
    # then renamed, so the reader never sees a half-written line.
    line <- paste0(.shiny_pb$value, "\t", gsub("[\t\r\n]+", " ", .shiny_pb$detail))
    tmp <- paste0(progress_file, ".new")
    tryCatch({
      writeLines(enc2utf8(line), tmp, useBytes = TRUE)
      file.rename(tmp, progress_file)
    }, error = function(e) NULL, warning = function(w) NULL)
    return(invisible())
  }

  tryCatch(suppressWarnings(shiny::setProgress(value = value, detail = detail)),
           error = function(e) NULL)
  invisible()
}

# Fill a pb() format string with the current values, dropping the tokens that
# only make sense in a console (the bar itself, spinner, timers).
.shiny_pb_text <- function(format, tokens, current, total) {
  text <- format
  for (nm in names(tokens)) {
    text <- gsub(paste0(":", nm), as.character(tokens[[nm]]), text, fixed = TRUE)
  }
  text <- gsub(":current", current, text, fixed = TRUE)
  text <- gsub(":total", if (is.na(total)) "?" else total, text, fixed = TRUE)
  text <- gsub(":(bar|spin|elapsedfull|elapsed|eta|percent|rate|bytes|tick_rate)",
               "", text)
  text <- gsub("\\(\\s*\\)|\\[\\s*\\]", "", text)
  .shiny_pb_tidy(text)
}

# Show a file path as just its file name: the full path ("Downloading to:
# /home/daniel/ShinyApps/...") would show visitors the server's folders. Web
# links are left alone (the lookbehind skips the slashes after "https:").
.shiny_pb_tidy <- function(text) {
  text <- gsub("(?<![A-Za-z0-9:/.])(?:[A-Za-z]:)?/(?:[^\\s/]+/)+([^\\s/]+)",
               "\\1", text, perl = TRUE)
  trimws(gsub("\\s+", " ", text))
}

#' Drop-in replacement for metacheck's pb() that reports to Shiny
shiny_pb <- function(total = NA, format = "[:bar] :current/:total") {
  current <- 0

  tick <- function(len = 1, tokens = list()) {
    current <<- current + len
    what <- as.character(tokens$what %||% "")
    n_mod <- length(.shiny_pb$modules)
    from <- .shiny_pb$range[1]
    span <- .shiny_pb$range[2] - from

    # report_module_run() labels its own bar with the module about to run
    # (len = 0) and ticks it again once that module has finished.
    idx <- match(what, .shiny_pb$modules)
    if (!is.na(idx)) {
      # Between modules (and after the last one, while the report is written)
      # messages are shown on their own, not under a finished module's label.
      .shiny_pb$module <- if (len == 0) idx else 0L
      done <- if (len == 0) idx - 1 else idx
      detail <- if (len == 0) {
        sprintf("%s (step %d of %d)", .shiny_pb$labels[idx], idx, n_mod)
      } else if (idx == n_mod) {
        # After the last module, the report itself is written (Quarto), which
        # takes a while and reports no progress of its own.
        "Writing the report"
      } else {
        sprintf("Finished %s (step %d of %d)", .shiny_pb$labels[idx], idx, n_mod)
      }
      .shiny_pb_send(value = from + span * done / n_mod, detail = detail,
                     force = TRUE)
      return(invisible())
    }

    # Any other bar: show its own text under the current module's label and,
    # when it counts several items (e.g. "Downloading files 12/80"), move the
    # bar through that module's share. A one-item bar (e.g. "OSF Info 1/1")
    # would jump straight to the end of the share, so it only updates the text.
    text <- .shiny_pb_text(format, tokens, current, total)
    if (!nzchar(text)) return(invisible())
    m <- .shiny_pb$module
    value <- NULL
    if (m > 0 && n_mod > 0) {
      text <- sprintf("%s (step %d of %d): %s", .shiny_pb$labels[m], m, n_mod, text)
      if (!is.na(total) && total > 1) {
        value <- from + span * (m - 1 + min(current / total, 1)) / n_mod
      }
    }
    # A bar without a count only ticks when something new starts (e.g.
    # "Writing the report"), so its messages are always sent; counting bars
    # can tick many times a second and are limited to one update per 0.2 s.
    .shiny_pb_send(value = value, detail = text, force = is.na(total))
    invisible()
  }

  message <- function(msg, ...) {
    .shiny_pb_send(detail = .shiny_pb_tidy(paste(msg, collapse = " ")))
  }

  terminate <- function(...) invisible()

  list(tick = tick, message = message, terminate = terminate)
}
