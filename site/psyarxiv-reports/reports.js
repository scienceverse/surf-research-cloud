// PsyArXiv reports page (prototype; site/psyarxiv-reports/, at /psyarxiv-reports/):
//   no parameters        the list of reports (GET /api/psyarxiv-reports)
//   ?id=<id>             one report, with "If the report contains mistakes,
//                        let us know" and a button (POST .../feedback)
//   ?delete=<id>&key=... the delete page that the mailed delete button opens
//                        (POST .../delete with the key)
// The reports themselves are static files at /psyarxiv-reports-files/<id>.html.
"use strict";

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
  const button = el("button", { type: "button", class: "mistake-button" }, "Report a mistake");
  button.addEventListener("click", () => openMistake(id));
  view.replaceChildren(
    el("div", { class: "report-bar" },
      el("div", { class: "report-info" },
        el("strong", {}, m.title || id), el("br"),
        el("span", { class: "note" },
          "PsyArXiv " + id + ", version " + m.version + " · checked " + day(m.generated) +
          " with metacheck " + (m.metacheck_version || "") + " · ",
          el("a", { href: m.url, target: "_blank", rel: "noopener" }, "the preprint on PsyArXiv"))),
      el("div", { class: "report-feedback" },
        el("span", {}, "If the report contains mistakes, let us know."), button)),
    el("iframe", { class: "report-frame", src: FILES + id + ".html", title: "metacheck report" }));
}

function openMistake(id) {
  const dlg = document.getElementById("mistake");
  const form = document.getElementById("mistake-form");
  const status = dlg.querySelector(".dialog-status");
  const send = document.getElementById("mistake-send");
  status.textContent = ""; send.disabled = false; form.reset();
  document.getElementById("mistake-cancel").onclick = () => dlg.close();
  form.onsubmit = async e => {
    e.preventDefault();
    send.disabled = true; status.textContent = "Sending…";
    try {
      const r = await fetch(API + "/psyarxiv-reports/" + id + "/feedback", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: form.message.value, email: form.email.value }) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
      status.textContent = "Thank you. Your message was sent to the people who run these reports; they will look at the report, and correct or remove it.";
      setTimeout(() => dlg.close(), 4000);
    } catch (err) {
      status.textContent = err.message; send.disabled = false;
    }
  };
  dlg.showModal();
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
