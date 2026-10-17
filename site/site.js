// metacheck website (SURF Research Cloud component, scienceverse/surf-research-cloud).
// Sends files to the web interface (/api/jobs), follows each job
// (/api/jobs/<id>) and offers the result. A folder is packed into a .zip in
// the browser with JSZip (vendor/jszip.min.js) before it is sent.
"use strict";

const API = "/api";
const MB = 1024 * 1024;
const LIMITS = {               // the web interface's own limits (api/api.R)
  paper: 50 * MB,
  zip: 500 * MB,
  unpacked: 1000 * MB,         // metacheck's repository check app
  files: 20000
};
const SKIP = /(^|\/)(\.git|\.svn|\.hg)(\/|$)|(^|\/)(\.DS_Store|Thumbs\.db|desktop\.ini)$/i;
let busyJobs = 0;

// ---- small helpers ---------------------------------------------------------

function el(tag, attrs, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k === "class") node.className = v; else node.setAttribute(k, v);
  }
  for (const c of children) node.append(c);
  return node;
}

function sizeText(bytes) {
  return bytes >= MB ? (bytes / MB).toFixed(bytes >= 10 * MB ? 0 : 1) + " MB"
                     : Math.max(1, Math.round(bytes / 1024)) + " kB";
}

function baseName(name) {
  return (name || "").replace(/^.*[\\/]/, "").replace(/\.[^.]*$/, "") || "paper";
}

async function errorText(response) {
  try {
    const j = await response.json();
    if (j && j.error) return j.error;
  } catch (e) { /* not JSON */ }
  return "The server answered with an error (HTTP " + response.status + ").";
}

// ---- the status area of one tool -------------------------------------------

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
      box.replaceChildren(el("div", { class: "error", role: "alert" }, message));
    },
    result(children) {
      box.replaceChildren(el("div", { class: "results" }, ...children));
    }
  };
}

// ---- sending a job and following it ----------------------------------------

// POST /api/jobs with upload progress (fetch cannot report it, XMLHttpRequest can).
function upload(form, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", API + "/jobs");
    xhr.upload.onprogress = e => { if (e.lengthComputable) onProgress(e.loaded / e.total); };
    xhr.onload = () => resolve(new Response(xhr.response, { status: xhr.status }));
    xhr.onerror = () => reject(new Error("The upload failed. Check your connection and try again."));
    xhr.responseType = "blob";
    xhr.send(form);
  });
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function runJob(section, file, filename, kind, fields, ui) {
  const form = new FormData();
  form.append("kind", kind);
  form.append("source", "website");   // for the use log: website or code
  for (const [k, v] of Object.entries(fields || {})) form.append(k, v);
  if (file) form.append("file", file, filename);

  ui.progress(0, file ? "Uploading " + sizeText(file.size) + "…" : "Sending the link…");
  const r = await upload(form, f => ui.progress(f, "Uploading: " + Math.round(f * 100) + "%"));
  if (r.status !== 202) throw new Error(await errorText(r));
  const job = await r.json();

  // follow the job until it is done
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
      const step = st.step ? st.step.charAt(0).toUpperCase() + st.step.slice(1) : "Working";
      ui.progress(st.progress !== undefined ? st.progress : null, step + "…");
    } else if (st.status === "failed") {
      throw new Error(st.error || "The job failed.");
    } else if (st.status === "done") {
      break;
    }
    await sleep(2000);
  }

  ui.progress(1, "Fetching the result…");
  const res = await fetch(job.result_url, { cache: "no-store" });
  if (!res.ok) throw new Error(await errorText(res));
  return res.blob();
}

function offerResult(ui, blob, kind, name) {
  const url = URL.createObjectURL(blob);
  if (kind === "convert") {
    ui.result([
      el("a", { class: "result-button", href: url, download: name + ".json" }, "Download the JSON"),
      el("a", { class: "result-button secondary", href: url, target: "_blank", rel: "noopener" }, "Open the JSON")
    ]);
  } else {
    ui.result([
      el("a", { class: "result-button", href: url, target: "_blank", rel: "noopener" }, "Open the report"),
      el("a", { class: "result-button secondary", href: url, download: name + "_metacheck_report.html" }, "Download the report"),
      el("p", { class: "note" }, "The report is kept on the server for one hour. Download it to keep it.")
    ]);
  }
}

async function start(section, getUpload, kind, fields) {
  const button = section.querySelector("button.go");
  const ui = statusArea(section);
  button.disabled = true;
  busyJobs++;
  try {
    const { file, filename, name } = await getUpload(ui);
    const blob = await runJob(section, file, filename, kind, fields, ui);
    offerResult(ui, blob, kind, name);
  } catch (e) {
    ui.error(e.message || String(e));
  } finally {
    busyJobs--;
    button.disabled = false;
  }
}

window.addEventListener("beforeunload", e => {
  if (busyJobs > 0) { e.preventDefault(); e.returnValue = ""; }
});

// ---- tools 1 and 2: a single paper -----------------------------------------

function setupPaperTool(section, kind) {
  const label = section.querySelector(".drop");
  const input = label.querySelector("input[type=file]");
  const text = label.querySelector(".drop-text");
  const button = section.querySelector("button.go");
  const allowJson = label.dataset.accept === "pdf-json";
  let chosen = null;

  function choose(file) {
    chosen = null;
    button.disabled = true;
    label.classList.remove("has-file");
    if (!file) return;
    const isPdf = /\.pdf$/i.test(file.name) || file.type === "application/pdf";
    const isJson = /\.json$/i.test(file.name) || file.type === "application/json";
    const ui = statusArea(section);
    if (!(isPdf || (allowJson && isJson))) {
      ui.error(allowJson ? "Choose a PDF or a bibr JSON file." : "Choose a PDF file.");
      return;
    }
    if (file.size > LIMITS.paper) {
      ui.error("This file is " + sizeText(file.size) + "; the limit is 50 MB.");
      return;
    }
    section.querySelector(".status").hidden = true;
    chosen = file;
    text.textContent = file.name + " (" + sizeText(file.size) + ")";
    label.classList.add("has-file");
    button.disabled = false;
  }

  input.addEventListener("change", () => choose(input.files[0]));
  label.addEventListener("dragover", e => { e.preventDefault(); label.classList.add("dragging"); });
  label.addEventListener("dragleave", () => label.classList.remove("dragging"));
  label.addEventListener("drop", e => {
    e.preventDefault();
    label.classList.remove("dragging");
    choose(e.dataTransfer.files[0]);
  });

  button.addEventListener("click", () => {
    if (!chosen) return;
    const fields = {};
    const crossref = section.querySelector(".use-crossref");
    fields.crossref = crossref && crossref.checked ? "true" : "false";
    if (kind === "report") {
      const mods = [...section.querySelectorAll(".check-list input:checked")].map(i => i.value);
      if (!mods.length) { statusArea(section).error("Choose at least one check."); return; }
      fields.modules = mods.join(",");
    }
    const file = chosen;
    start(section, async () => ({ file, filename: file.name, name: baseName(file.name) }), kind, fields);
  });
}

// The checks for a report, from GET /api/modules: the default set ticked.
async function loadModules(section) {
  const list = section.querySelector(".check-list");
  const count = section.querySelector(".checks-count");
  try {
    const r = await fetch(API + "/modules");
    if (!r.ok) throw new Error();
    const m = await r.json();
    const info = Array.isArray(m.info) && m.info.length
      ? m.info : m.allowed.map(name => ({ name, title: name, description: "", default: m.default.includes(name) }));
    const group = (heading, rows) => {
      if (!rows.length) return [];
      return [el("h3", {}, heading), ...rows.map(row => {
        const box = el("input", { type: "checkbox", value: row.name });
        box.checked = !!row.default;
        box.addEventListener("change", update);
        const lab = el("label", { title: row.description || "" }, box, el("span", {}, row.title || row.name));
        return lab;
      })];
    };
    list.replaceChildren(
      ...group("Default checks", info.filter(x => x.default)),
      ...group("Checks that contact other services", info.filter(x => !x.default))
    );
    function update() {
      const all = list.querySelectorAll("input").length;
      const on = list.querySelectorAll("input:checked").length;
      count.textContent = "(" + on + " of " + all + ")";
    }
    update();
  } catch (e) {
    list.replaceChildren(el("p", { class: "note" }, "The list of checks could not be loaded; the default checks will be used."));
  }
}

// ---- tool 3: a data and code folder ----------------------------------------

// Every file under a dropped folder (DataTransfer entries; readEntries
// returns at most about 100 entries per call, so it is called until empty).
async function filesFromEntry(entry, out) {
  if (entry.isFile) {
    const file = await new Promise((res, rej) => entry.file(res, rej));
    out.push({ file, path: entry.fullPath.replace(/^\/+/, "") });
  } else if (entry.isDirectory) {
    const reader = entry.createReader();
    for (;;) {
      const batch = await new Promise((res, rej) => reader.readEntries(res, rej));
      if (!batch.length) break;
      for (const child of batch) await filesFromEntry(child, out);
    }
  }
}

function setupFolderTool(section) {
  const drop = section.querySelector(".drop-folder");
  const text = drop.querySelector(".drop-text");
  const button = section.querySelector("button.go");
  const pickFolder = drop.querySelector(".pick-folder");
  const pickZip = drop.querySelector(".pick-zip");
  const urlInput = section.querySelector(".repo-url");
  let chosen = null;   // { zip: File }, { files: [{file, path}], name } or { url }

  function reset() {
    chosen = null;
    button.disabled = true;
    drop.classList.remove("has-file");
    text.textContent = "Drop a folder or a .zip file here";
  }

  // A link replaces a chosen folder or .zip, and the other way round.
  urlInput.addEventListener("input", () => {
    const url = urlInput.value.trim();
    if (url) {
      reset();
      section.querySelector(".status").hidden = true;
      chosen = { url };
      button.disabled = false;
    } else if (chosen && chosen.url) {
      reset();
    }
  });

  function chooseZip(file) {
    reset();
    urlInput.value = "";
    if (!/\.zip$/i.test(file.name)) { statusArea(section).error("Choose a folder or a .zip file."); return; }
    if (file.size > LIMITS.zip) {
      statusArea(section).error("This .zip file is " + sizeText(file.size) + "; the limit is 500 MB. Leave out large data or output files that do not need checking.");
      return;
    }
    section.querySelector(".status").hidden = true;
    chosen = { zip: file };
    text.textContent = file.name + " (" + sizeText(file.size) + ")";
    drop.classList.add("has-file");
    button.disabled = false;
  }

  function chooseFiles(all) {
    reset();
    urlInput.value = "";
    const files = all.filter(f => !SKIP.test(f.path));
    if (!files.length) { statusArea(section).error("The folder has no files to check."); return; }
    const total = files.reduce((s, f) => s + f.file.size, 0);
    const ui = statusArea(section);
    if (files.length > LIMITS.files) {
      ui.error("The folder has " + files.length + " files; the limit is 20,000. Leave out folders that do not need checking, such as renv/ or node_modules/.");
      return;
    }
    if (total > LIMITS.unpacked) {
      ui.error("The folder holds " + sizeText(total) + "; the limit is 1000 MB. Leave out large data or output files that do not need checking.");
      return;
    }
    section.querySelector(".status").hidden = true;
    const tops = new Set(files.map(f => f.path.split("/")[0]));
    const name = tops.size === 1 && files.every(f => f.path.includes("/")) ? [...tops][0] : "folder";
    chosen = { files, name };
    const skipped = all.length - files.length;
    text.textContent = name + ": " + files.length + " files, " + sizeText(total) +
      (skipped ? " (" + skipped + " version control files left out)" : "");
    drop.classList.add("has-file");
    button.disabled = false;
  }

  pickZip.addEventListener("change", () => { if (pickZip.files[0]) chooseZip(pickZip.files[0]); });
  pickFolder.addEventListener("change", () => {
    chooseFiles([...pickFolder.files].map(file => ({ file, path: file.webkitRelativePath || file.name })));
  });

  drop.addEventListener("dragover", e => { e.preventDefault(); drop.classList.add("dragging"); });
  drop.addEventListener("dragleave", () => drop.classList.remove("dragging"));
  drop.addEventListener("drop", async e => {
    e.preventDefault();
    drop.classList.remove("dragging");
    // the entries must be taken before the first await
    const entries = [...e.dataTransfer.items]
      .map(i => (i.webkitGetAsEntry ? i.webkitGetAsEntry() : null)).filter(Boolean);
    const loose = [...e.dataTransfer.files];
    if (entries.length === 1 && entries[0].isFile && /\.zip$/i.test(entries[0].name)) {
      chooseZip(loose[0]);
      return;
    }
    if (!entries.length) {
      if (loose.length === 1) chooseZip(loose[0]);
      return;
    }
    text.textContent = "Reading the folder…";
    try {
      const out = [];
      for (const entry of entries) await filesFromEntry(entry, out);
      chooseFiles(out);
    } catch (err) {
      reset();
      statusArea(section).error("The folder could not be read: " + (err.message || err));
    }
  });

  button.addEventListener("click", () => {
    if (!chosen) return;
    const c = chosen;
    const fields = { run_code: section.querySelector(".run-code").checked ? "true" : "false" };
    if (c.url) fields.url = c.url;
    start(section, async ui => {
      if (c.url) {
        const name = c.url.replace(/^https?:\/\//i, "").replace(/[\/?#]+$/, "").split("/").filter(Boolean).slice(-1)[0] || "repository";
        return { file: null, filename: null, name };
      }
      if (c.zip) return { file: c.zip, filename: c.zip.name, name: baseName(c.zip.name) };
      const zip = new JSZip();
      for (const f of c.files) zip.file(f.path, f.file, { date: new Date(f.file.lastModified || Date.now()) });
      ui.progress(0, "Packing the folder…");
      const blob = await zip.generateAsync(
        { type: "blob", compression: "DEFLATE", compressionOptions: { level: 1 } },
        meta => ui.progress(meta.percent / 100, "Packing the folder: " + Math.round(meta.percent) + "%")
      );
      if (blob.size > LIMITS.zip) {
        throw new Error("The packed folder is " + sizeText(blob.size) + "; the limit is 500 MB. Leave out large data or output files that do not need checking.");
      }
      return { file: blob, filename: c.name + ".zip", name: c.name };
    }, "repocheck", fields);
  });
}

// ---- start -------------------------------------------------------------------

setupPaperTool(document.getElementById("tool-report"), "report");
setupPaperTool(document.getElementById("tool-convert"), "convert");
setupFolderTool(document.getElementById("tool-folder"));
loadModules(document.getElementById("tool-report"));

document.getElementById("curl-example").textContent =
  "curl -F file=@paper.pdf " + location.origin + "/api/report -o report.html";

fetch(API + "/health").then(r => r.json()).then(h => {
  if (h.metacheck_version) document.getElementById("version").textContent = "Metacheck version " + h.metacheck_version + ".";
  if (h.run_code === false) {
    // this server cannot run code: the repository check runs without it
    const box = document.querySelector("#tool-folder .run-code");
    box.checked = false;
    box.disabled = true;
    document.querySelector("#tool-folder .run-code-note").textContent = "(not available on this server at the moment)";
  }
}).catch(() => {});
