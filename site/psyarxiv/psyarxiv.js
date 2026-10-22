// PsyArXiv Check page (site/psyarxiv/): the preprint's record from PsyArXiv's
// API (read in the browser: the API allows any website), with checks of the
// record itself, and metacheck's checklist report on the paper from this
// server (POST /api/jobs, kind=report, psyarxiv=<id>, report_type=checklist,
// every paper module this server offers). The server fetches the PDF itself:
// PsyArXiv's files send no CORS header, so a page cannot fetch them.
"use strict";

const PSYARXIV_API = "https://next.psyarxiv.org/api/v1";
const PSYARXIV_SITE = "https://next.psyarxiv.org";
const records = {};   // id -> record (or an Error)

// An id from a PsyArXiv, OSF or psyarxiv.com link, a PsyArXiv DOI, or an id.
function psyarxivId(link) {
  let x = link.trim();
  x = x.replace(/^https?:\/\/(dx\.)?doi\.org\//i, "");
  x = x.replace(/^(doi:)?10\.31234\/osf\.io\//i, "");
  x = x.replace(/^https?:\/\/[^\/]+\/(preprints?\/(psyarxiv\/)?)?/i, "");
  x = x.replace(/[\/?#].*$/, "").replace(/_v\d+$/i, "").toLowerCase();
  if (!/^[a-z0-9]{5,12}$/.test(x)) throw new Error("not a PsyArXiv link");
  return x;
}

async function record(id) {
  if (!records[id]) {
    records[id] = fetch(PSYARXIV_API + "/preprints/" + id)
      .then(async r => {
        if (r.status === 404) throw new Error("PsyArXiv has no preprint with the id " + id + ".");
        if (!r.ok) throw new Error("PsyArXiv did not answer (HTTP " + r.status + ").");
        return r.json();
      });
  }
  return records[id];
}

// The record's own checks, as {status, title, found, todo}: the same ones as
// the PsyArXiv Check app on the TU/e Shiny server.
function recordChecks(rec) {
  const out = [];
  const link = u => el("a", { href: u, target: "_blank", rel: "noopener" }, u);
  const links = us => { const s = el("span"); us.forEach((u, i) => { if (i) s.append(", "); s.append(link(u)); }); return s; };
  const sup = rec.supplements, dl = rec.dataLinks || [];
  if (rec.dataStatus === "available") {
    if (sup && sup.status === "private") {
      out.push({ status: "fix", title: "Open data can be reached",
        found: el("span", {}, "The preprint says its data are open, but the linked OSF project (", link(sup.url), ") is private."),
        todo: "Make the OSF project public, or link the data where readers can reach them." });
    } else if (sup && sup.status === "deleted") {
      out.push({ status: "fix", title: "Open data can be reached",
        found: "The preprint says its data are open, but the linked OSF project has been deleted.",
        todo: "Link the data where readers can reach them." });
    } else if (dl.length) {
      out.push({ status: "fine", title: "Open data can be reached", found: el("span", {}, "The data are linked: ", links(dl), ".") });
    } else {
      out.push({ status: "improve", title: "Open data can be reached",
        found: "The preprint says its data are open, but gives no link to them.", todo: "Add the link to the data on PsyArXiv." });
    }
  } else if (rec.dataStatus === "no") {
    out.push({ status: "improve", title: "Open data", found: "The preprint says its data are not shared.",
      todo: "Share the data if you can, or explain on PsyArXiv why they cannot be shared." });
  } else {
    out.push({ status: "improve", title: "Open data", found: "The preprint does not say whether its data are available.",
      todo: "Fill in the data statement on PsyArXiv." });
  }

  const pl = rec.preregLinks || [];
  if (rec.preregStatus === "available" && pl.length) {
    out.push({ status: "fine", title: "Preregistration", found: el("span", {}, "Preregistered: ", links(pl), ".") });
  } else if (rec.preregStatus === "available") {
    out.push({ status: "improve", title: "Preregistration", found: "The preprint says the study was preregistered, but gives no link.",
      todo: "Add the link to the preregistration." });
  } else if (rec.preregStatus === "no") {
    out.push({ status: "info", title: "Preregistration", found: "The preprint says the study was not preregistered." });
  } else {
    out.push({ status: "improve", title: "Preregistration", found: "The preprint does not say whether the study was preregistered.",
      todo: "Fill in the preregistration statement on PsyArXiv." });
  }

  const lic = rec.license && rec.license.name;
  if (!lic || /^no license/i.test(lic)) {
    out.push({ status: "improve", title: "License", found: "The preprint has no license, so others may not reuse it.",
      todo: "Choose a license on PsyArXiv, for example CC BY 4.0." });
  } else {
    out.push({ status: "fine", title: "License", found: "The preprint is licensed " + lic + "." });
  }

  if (rec.hasCoi === null || rec.hasCoi === undefined) {
    out.push({ status: "improve", title: "Conflict of interest statement",
      found: "The preprint does not say whether the authors have a conflict of interest.",
      todo: "Fill in the conflict of interest statement on PsyArXiv." });
  } else if (rec.hasCoi) {
    out.push({ status: "info", title: "Conflict of interest statement",
      found: "The authors declare a conflict of interest: " + (rec.coiStatement || "(no statement given)") + "." });
  } else {
    out.push({ status: "fine", title: "Conflict of interest statement", found: "The authors declare no conflict of interest." });
  }

  const au = rec.authors || [];
  if (au.length) {
    const has = au.filter(a => a.orcid).length, ver = au.filter(a => a.orcidVerified).length;
    out.push({ status: has === au.length ? "fine" : "improve", title: "Authors' ORCID iDs",
      found: has + " of the " + au.length + " authors have an ORCID iD on their OSF profile (" + ver + " verified by the OSF).",
      todo: has < au.length ? "Authors without an ORCID iD can add one to their OSF profile, so their work is linked to them." : null });
  }
  if (rec.publicationDoi) {
    out.push({ status: "info", title: "Published version",
      found: el("span", {}, "Published as ", link("https://doi.org/" + rec.publicationDoi), ".") });
  }
  return out;
}

const STATUS_LABEL = { fix: "To fix", improve: "To improve", manual: "To decide by hand", fine: "Fine", na: "Not applicable", info: "For information" };

function recordCard(rec) {
  const authors = (rec.authors || []).map(a => a.name).join(", ");
  const checks = recordChecks(rec);
  const order = ["fix", "improve", "manual", "fine", "info", "na"];
  checks.sort((a, b) => order.indexOf(a.status) - order.indexOf(b.status));
  return el("div", { class: "record" },
    el("h3", {}, rec.title || rec.id),
    el("p", { class: "record-authors" }, authors),
    el("p", { class: "record-meta" },
      "Version " + rec.version + ", posted " + String(rec.versionPostedAt || "").slice(0, 10) + " · ",
      el("a", { href: "https://doi.org/" + rec.doi, target: "_blank", rel: "noopener" }, rec.doi), " · ",
      el("a", { href: PSYARXIV_SITE + "/preprint/" + rec.id, target: "_blank", rel: "noopener" }, "on PsyArXiv")),
    el("h4", {}, "The PsyArXiv record"),
    ...checks.map(c => el("div", { class: "rcheck " + c.status },
      el("span", { class: "badge " + c.status }, STATUS_LABEL[c.status]),
      el("strong", {}, c.title), " ",
      el("span", { class: "rfound" }, c.found),
      c.todo ? el("span", { class: "rtodo" }, " What to do: " + c.todo) : null)),
    el("p", { class: "note" }, rec.state === "withdrawn" ? "This preprint was withdrawn; it cannot be checked." :
      "The report below checks the paper itself, with every module this server offers."));
}

async function showRecord(id) {
  const box = document.querySelector(".record-box");   // below the form, outside its section
  box.hidden = false;
  box.replaceChildren(el("p", { class: "note" }, "Looking the preprint up on PsyArXiv…"));
  try {
    box.replaceChildren(recordCard(await record(id)));
  } catch (e) {
    box.replaceChildren(el("div", { class: "error" }, e.message || String(e)));
  }
}

let allowedModules = null;
fetch(API + "/modules").then(r => r.json()).then(m => { allowedModules = m.allowed; }).catch(() => {});

setupLinkCheck(document.getElementById("tool-psyarxiv"), {
  parse: psyarxivId,
  onChange: showRecord,
  async fields(id, section) {
    const rec = await record(id);   // stops here with PsyArXiv's message for an unknown id
    if (rec.state === "withdrawn") throw new Error("This preprint was withdrawn from PsyArXiv; it has no file to check.");
    const fields = {
      kind: "report",
      psyarxiv: id,
      report_type: "checklist",
      crossref: section.querySelector("input.crossref-box").checked ? "true" : "false",
      run_code: section.querySelector("input.run-code").checked ? "true" : "false"
    };
    if (allowedModules && allowedModules.length) fields.modules = allowedModules.join(",");
    return fields;
  },
  filename: id => "psyarxiv_" + id + "_metacheck.html"
});
