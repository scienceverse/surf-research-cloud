// PsyArXiv reports page (prototype; site/psyarxiv-reports/, at /psyarxiv-reports/):
//   no parameters        the list of reports (GET /api/psyarxiv-reports)
//   ?id=<id>             one report, with "If the report contains mistakes,
//                        let us know" and two links: a mail to MISTAKE_MAIL and
//                        a new GitHub issue, both with the preprint filled in
//   ?delete=<id>&key=... the delete page for links from mails (POST .../delete
//                        with the key); no mails are sent yet (no SMTP account)
// The reports themselves are static files at /psyarxiv-reports-files/<id>.html.
"use strict";

const MISTAKE_MAIL = "metacheck.scienceverse@gmail.com";
const MISTAKE_ISSUES = "https://github.com/scienceverse/metacheck/issues/new";
const API = (new URLSearchParams(location.search).get("api") || (location.origin + "/api")).replace(/\/+$/, "");
const FILES = API.replace(/\/api$/, "") + "/psyarxiv-reports-files/";
const params = new URLSearchParams(location.search);
const view = document.getElementById("view");

function el(tag, attrs, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k === "class") node.className = v; else node.setAttribute(k, v);
  }
  for (const c of children) if (c !== null && c !== undefined) node.append(c);
  return node;
}
const validId = id => /^[a-z0-9]{5,12}$/.test(id || "");
async function getJson(url) {
  const r = await fetch(url, { cache: "no-store" });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) { const e = new Error(j.error || ("HTTP " + r.status)); e.data = j; throw e; }
  return j;
}
function message(title, text) {
  view.replaceChildren(el("div", { class: "message pad" }, el("h2", {}, title), el("p", {}, text),
    el("p", {}, el("a", { href: "./" }, "All reports"))));
}
const day = s => String(s || "").slice(0, 10);

async function showList() {
  document.title = "PsyArXiv Reports";
  let list;
  try { list = (await getJson(API + "/psyarxiv-reports")).reports || []; }
  catch (e) { message("Not available", e.message); return; }
  view.replaceChildren(el("div", { class: "pad" },
    el("h2", {}, "Reports"),
    el("p", { class: "note" }, "Automated checklist reports on the newest PsyArXiv preprints, made with metacheck. They miss things and flag things that are fine: read every finding as a question, not a verdict."),
    list.length ? el("ul", { class: "report-list" }, ...list.map(r => el("li", {},
      el("a", { href: "?id=" + encodeURIComponent(r.id) }, r.title || r.id),
      el("span", { class: "note" }, " · " + [].concat(r.authors || []).slice(0, 3).join(", ") +
         ((r.authors || []).length > 3 ? " et al." : "") + " · posted " + day(r.posted)))))
      : el("p", {}, "No reports yet.")));
}

async function showReport(id) {
  let m;
  try { m = await getJson(API + "/psyarxiv-reports/" + id); }
  catch (e) { message(e.data && e.data.deleted ? "Report removed" : "No report", e.message); return; }
  document.title = (m.title || id) + " · metacheck report";
  const subject = "Mistake in the metacheck report on PsyArXiv " + id + ", version " + m.version;
  const body = "Report: " + location.origin + location.pathname + "?id=" + id +
    "\nPreprint: " + (m.title || id) + "\n\nWhich check, and what is wrong:\n";
  const mail = el("a", { class: "mistake-button", href: "mailto:" + MISTAKE_MAIL +
    "?subject=" + encodeURIComponent(subject) + "&body=" + encodeURIComponent(body) }, "Report a mistake by email");
  const issue = el("a", { class: "mistake-button", target: "_blank", rel: "noopener", href: MISTAKE_ISSUES +
    "?title=" + encodeURIComponent(subject) + "&body=" + encodeURIComponent(body) }, "Report a mistake on GitHub");
  view.replaceChildren(
    el("div", { class: "report-bar" },
      el("div", { class: "report-info" },
        el("strong", {}, m.title || id), el("br"),
        el("span", { class: "note" },
          "PsyArXiv " + id + ", version " + m.version + " · checked " + day(m.generated) +
          " with metacheck " + (m.metacheck_version || "") + " · ",
          el("a", { href: m.url, target: "_blank", rel: "noopener" }, "the preprint on PsyArXiv"))),
      el("div", { class: "report-feedback" },
        el("span", {}, "If the report contains mistakes, let us know."), mail, issue)),
    el("iframe", { class: "report-frame", src: FILES + id + ".html", title: "metacheck report" }));
}

async function showDelete(id, key) {
  let m;
  try { m = await getJson(API + "/psyarxiv-reports/" + id + "?key=" + encodeURIComponent(key)); }
  catch (e) { message(e.data && e.data.deleted ? "Already deleted" : "No report", e.message); return; }
  if (!m.key_valid) { message("Not allowed", "This delete link is not valid."); return; }
  const button = el("button", { type: "button", class: "mistake-button" }, "Delete the report");
  const status = el("p", { class: "note", role: "status" });
  button.addEventListener("click", async () => {
    button.disabled = true; status.textContent = "Deleting…";
    try {
      const r = await fetch(API + "/psyarxiv-reports/" + id + "/delete", {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ key }) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
      message("Deleted", "The report on " + (m.title || id) + " is removed and will not be made again.");
    } catch (err) { status.textContent = err.message; button.disabled = false; }
  });
  view.replaceChildren(el("div", { class: "message pad" },
    el("h2", {}, "Delete this report?"),
    el("p", {}, el("strong", {}, m.title || id), " (PsyArXiv " + id + ", version " + m.version + ")"),
    el("p", {}, "The report and its details are removed, and no report is made again for this preprint."),
    button, status,
    el("p", {}, el("a", { href: "?id=" + id }, "Look at the report first"))));
}

const del = params.get("delete"), id = params.get("id");
if (del !== null) validId(del) ? showDelete(del, params.get("key") || "") : message("Not found", "This page does not exist.");
else if (id !== null) validId(id) ? showReport(id) : message("No report", "That is not a PsyArXiv id.");
else showList();
