// Pages that check one link (site/researchbox/, site/psyarxiv/): the link goes
// to this server's web interface (POST /api/jobs, report_type=checklist), the
// page follows the job and offers metacheck's checklist report. Each page
// calls setupLinkCheck() with what it sends; site/psyarxiv/psyarxiv.js also
// shows the preprint's PsyArXiv record. A page address with ?api=<address>
// uses another metacheck server (for testing).
"use strict";

const API = (new URLSearchParams(location.search).get("api") || (location.origin + "/api")).replace(/\/+$/, "");
let busy = false;

function el(tag, attrs, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k === "class") node.className = v; else node.setAttribute(k, v);
  }
  for (const c of children) if (c !== null && c !== undefined) node.append(c);
  return node;
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function errorText(response) {
  try {
    const j = await response.json();
    if (j && j.error) return j.error;
  } catch (e) { /* not JSON */ }
  if ([502, 503, 504].includes(response.status)) {
    return "The server is not answering at the moment (HTTP " + response.status + "); it may be installing an update. Try again in a few minutes.";
  }
  return "The server answered with an error (HTTP " + response.status + ").";
}

function statusArea(section) {
  const box = section.querySelector(".status");
  box.hidden = false;
  box.replaceChildren();
  const bar = el("div", { class: "bar unknown" }, el("span"));
  const step = el("p", { class: "step" });
  box.append(bar, step);
  return {
    progress(fraction, text) {
      if (fraction === null || fraction === undefined) {
        bar.classList.add("unknown"); bar.firstChild.style.width = "";
      } else {
        bar.classList.remove("unknown");
        bar.firstChild.style.width = Math.round(Math.min(1, Math.max(0, fraction)) * 100) + "%";
      }
      if (text !== undefined) step.textContent = text;
    },
    error(message) {
      box.replaceChildren(el("div", { class: "error", role: "alert" }, ...[].concat(message)));
    },
    result(children) {
      box.replaceChildren(el("div", { class: "results" }, ...children));
    }
  };
}

// POST /api/jobs with the fields, follow the job, return the report (a Blob).
// A 502/503 when sending (the server restarting for an update) is tried
// again twice, half a minute apart.
async function runJob(fields, ui) {
  const form = new FormData();
  form.append("source", "website");
  for (const [k, v] of Object.entries(fields)) form.append(k, v);
  ui.progress(null, "Sending…");
  let r;
  for (let attempt = 0; ; attempt++) {
    r = await fetch(API + "/jobs", { method: "POST", body: form });
    if (![502, 503].includes(r.status) || attempt >= 2) break;
    ui.progress(null, "The server is busy restarting; trying again in half a minute…");
    await sleep(30000);
  }
  if (r.status !== 202) throw new Error(await errorText(r));
  const job = await r.json();

  let failures = 0;
  for (;;) {
    let st;
    try {
      const s = await fetch(job.status_url, { cache: "no-store" });
      if (!s.ok) throw new Error(await errorText(s));
      st = await s.json();
      failures = 0;
    } catch (e) {
      if (++failures >= 5) throw e;
      await sleep(3000);
      continue;
    }
    if (st.status === "queued") {
      ui.progress(null, "Waiting in the queue" + (st.position ? " (position " + st.position + ")" : "") + "…");
    } else if (st.status === "running") {
      const step = st.step ? st.step.charAt(0).toUpperCase() + st.step.slice(1) : "Checking";
      ui.progress(st.progress !== undefined ? st.progress : null, step + "… (this takes a few minutes)");
    } else if (st.status === "failed") {
      throw new Error(st.error || "The check failed.");
    } else if (st.status === "done") {
      break;
    }
    await sleep(3000);
  }
  ui.progress(1, "Fetching the report…");
  const res = await fetch(job.result_url, { cache: "no-store" });
  if (!res.ok) throw new Error(await errorText(res));
  return res.blob();
}

// ---- the visitor's own API keys ----------------------------------------------
// When a key the server provides (GitHub, OSF, Dryad, ResearchBox, GitLab,
// OpenAlex) was refused or reached its limit, GET /health lists it in
// key_problems. The page then says so and offers a field for the visitor's own
// key, sent with the check as key_<service> and used for that check only.
function showKeyProblems(section, problems) {
  let box = section.querySelector(".key-problems");
  if (!problems || !problems.length) {
    if (box) box.remove();
    return;
  }
  if (!box) {
    box = el("div", { class: "key-problems" });
    section.querySelector("button.go").before(box);
  }
  box.replaceChildren(...problems.map(p => el("div", { class: "key-problem" },
    el("p", {}, p.message),
    el("label", {}, "Your own " + p.label + " key (used for this check only): ",
      el("input", { type: "password", class: "own-key", "data-service": p.service,
                    autocomplete: "off", spellcheck: "false" })))));
}

function ownKeys(section) {
  const keys = {};
  for (const input of section.querySelectorAll("input.own-key")) {
    const v = input.value.trim();
    if (v) keys["key_" + input.dataset.service] = v;
  }
  return keys;
}

function offerReport(ui, blob, filename, extra) {
  const url = URL.createObjectURL(new Blob([blob], { type: "text/html" }));
  ui.result([
    ...(extra || []),
    el("a", { class: "result-button", href: url, target: "_blank", rel: "noopener" }, "Open the report"),
    el("a", { class: "result-button secondary", href: url, download: filename }, "Download the report"),
    el("p", { class: "note" }, "The report is kept on the server for one hour. Download it to keep it.")
  ]);
}

// opts: parse(link) -> the key part of the link, or throws with a message;
//       fields(key, section) -> the form fields to send;
//       filename(key) -> the report's file name;
//       onChange(key, section) (optional) -> called when a valid link is entered;
//       extra(key) (optional) -> elements to show above the report buttons.
function setupLinkCheck(section, opts) {
  const input = section.querySelector(".repo-url");
  const button = section.querySelector("button.go");
  const note = section.querySelector(".server-note");
  let key = null, serverReady = false, timer = null;

  function ready() { button.disabled = !(key && serverReady) || busy; }

  input.addEventListener("input", () => {
    clearTimeout(timer);
    const link = input.value.trim();
    key = null;
    if (link) {
      try { key = opts.parse(link); } catch (e) { key = null; }
    }
    ready();
    if (key && opts.onChange) timer = setTimeout(() => opts.onChange(key, section), 400);
  });

  button.addEventListener("click", async () => {
    if (!key || busy) return;
    const k = key;
    const ui = statusArea(section);
    busy = true;
    ready();
    try {
      const blob = await runJob(Object.assign({}, await opts.fields(k, section), ownKeys(section)), ui);
      offerReport(ui, blob, opts.filename(k), opts.extra ? opts.extra(k) : null);
    } catch (e) {
      ui.error(e.message || String(e));
    } finally {
      busy = false;
      ready();
    }
  });

  note.textContent = "Checking the server…";
  fetch(API + "/health", { cache: "no-store" })
    .then(r => { if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
    .then(h => {
      serverReady = true;
      showKeyProblems(section, h.key_problems);
      note.textContent = "Server: metacheck " + (h.metacheck_version || "") +
        (h.jobs_waiting ? " · " + h.jobs_waiting + " waiting" : "");
      const v = document.getElementById("version");
      if (v && h.metacheck_version) v.textContent = "Server: metacheck " + h.metacheck_version + ".";
      ready();
    })
    .catch(e => {
      note.textContent = "The metacheck server could not be reached (" + (e.message || e) + "). Try again later.";
      note.classList.add("warning");
    });

  window.addEventListener("beforeunload", e => { if (busy) { e.preventDefault(); e.returnValue = ""; } });
}
