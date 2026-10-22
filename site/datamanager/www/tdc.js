// TU/e Data Manager Check page (tue_datamanager_check, web/).
// Sends a data package to the web interface of a metacheck server on SURF
// Research Cloud (POST <api>/jobs, kind=repocheck, modules=tue_datamanager_check),
// follows the job (<api>/jobs/<id>) and offers the report. A folder is packed
// into a .zip in the browser with JSZip (www/jszip.min.js) before it is sent.
// The page can be served from any website, by Shiny (web/app.R) or opened from
// disk: the server allows web pages from anywhere (CORS).
"use strict";

const MODULE = "tue_datamanager_check";
const API = (new URLSearchParams(location.search).get("api") || window.TDC_API ||
             "https://metacheckserve.metacheck.src.surf-hosted.nl/api").replace(/\/+$/, "");
const MB = 1024 * 1024;
const LIMITS = {               // the web interface's limits (its api/api.R)
  zip: 500 * MB,
  unpacked: 1000 * MB,
  files: 20000
};
let busy = false;

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
  return (name || "").replace(/^.*[\\/]/, "").replace(/\.[^.]*$/, "") || "package";
}

async function errorText(response) {
  try {
    const j = await response.json();
    if (j && j.error) return j.error;
  } catch (e) { /* not JSON */ }
  if ([502, 503, 504].includes(response.status)) {
    return "The server is not answering at the moment (HTTP " + response.status + "). Try again in a few minutes.";
  }
  return "The server answered with an error (HTTP " + response.status + ").";
}

// ---- files the browser cannot read ------------------------------------------

// The browser lists a folder's files when it is chosen, but some of them it
// cannot read: on Windows, a file whose full path is longer than 260
// characters (the browser lists it as empty, or leaves it out without a
// word), a file OneDrive keeps online only, or a file opened, moved or
// deleted since. JSZip would stop on the first one with the browser's own
// message ("A requested file or directory could not be found at the time an
// operation was processed."), so every file is tried first: its first byte,
// or all of an empty file. Returns the paths that could not be read.
async function unreadableFiles(files, onProgress) {
  const bad = [];
  let next = 0, done = 0;
  async function worker() {
    while (next < files.length) {
      const f = files[next++];
      if (f.error) {
        bad.push(f.path);
      } else {
        try { await (f.file.size === 0 ? f.file : f.file.slice(0, 1)).arrayBuffer(); }
        catch (e) { bad.push(f.path); }
      }
      if (++done % 100 === 0) onProgress(done / files.length);
    }
  }
  await Promise.all(Array.from({ length: 8 }, worker));
  return bad.sort();
}

// What to do when files cannot be read (the reasons above), as the error box shows it.
function unreadableMessage(bad, total) {
  // the file's name and the end of its folder; the whole path on hover
  const short = p => {
    const name = p.replace(/\/$/, "").replace(/^.*\//, "");
    const dir = p.slice(0, p.length - name.length).replace(/\/+$/, "");
    const tail = dir.length > 40 ? "…" + dir.slice(-40) : dir;
    return el("li", { title: p }, name + (tail ? " (in " + tail + "/)" : ""));
  };
  const shown = bad.slice(0, 5).map(short);
  if (bad.length > 5) shown.push(el("li", {}, "and " + (bad.length - 5) + " more"));
  return [
    el("p", {}, "The browser could not read " + bad.length + " of the " + total +
       " files it found in the folder, so the folder cannot be checked as it is:"),
    el("ul", {}, ...shown),
    el("p", {}, "This usually has one of these causes:"),
    el("ul", {},
       el("li", {}, "The file's full path on this computer is longer than Windows allows (260 characters). Move the folder closer to the top of the drive, for example to C:\\check\\, and choose it again. Windows can also leave such files out without saying so: if the folder holds more than " + total + " files, that has happened too."),
       el("li", {}, "The file is in OneDrive but kept online only. Right-click the folder, choose \"Always keep on this device\", wait until it has downloaded, and choose it again."),
       el("li", {}, "The file is open in another program, or was moved or deleted after the folder was chosen.")),
    el("p", {}, "Or pack the folder into a .zip yourself, with 7-Zip (which handles long paths), and choose the .zip.")
  ];
}

const TOO_LARGE_ADVICE = " Leave out large files that do not need checking (such as recordings, images or videos), or paste the link to the online repository instead.";

const sleep = ms => new Promise(r => setTimeout(r, ms));

// ---- the status area ---------------------------------------------------------

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
    // a text, or a list of elements (paragraphs and lists)
    error(message) {
      box.replaceChildren(el("div", { class: "error", role: "alert" }, ...[].concat(message)));
    },
    result(children) {
      box.replaceChildren(el("div", { class: "results" }, ...children));
    }
  };
}

// ---- sending the package and following the job ---------------------------------

// POST <api>/jobs with upload progress (fetch cannot report it, XMLHttpRequest can).
function upload(form, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", API + "/jobs");
    xhr.upload.onprogress = e => { if (e.lengthComputable) onProgress(e.loaded / e.total); };
    xhr.onload = () => resolve(new Response(xhr.response, { status: xhr.status }));
    xhr.onerror = () => reject(new Error("The upload failed. Check your connection and try again; if it keeps failing, the server may be unreachable from this page."));
    xhr.responseType = "blob";
    xhr.send(form);
  });
}

async function runJob(file, filename, fields, ui) {
  const form = new FormData();
  form.append("kind", "repocheck");
  form.append("modules", MODULE);
  form.append("source", "website");   // for the server's use log: website or code
  for (const [k, v] of Object.entries(fields)) form.append(k, v);
  if (file) form.append("file", file, filename);

  ui.progress(0, file ? "Uploading " + sizeText(file.size) + "…" : "Sending the link…");
  const r = await upload(form, f => ui.progress(f, "Uploading: " + Math.round(f * 100) + "%"));
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

function offerReport(ui, blob, name) {
  const url = URL.createObjectURL(new Blob([blob], { type: "text/html" }));
  ui.result([
    el("a", { class: "result-button", href: url, target: "_blank", rel: "noopener" }, "Open the report"),
    el("a", { class: "result-button secondary", href: url, download: name + "_tue_check.html" }, "Download the report"),
    el("p", { class: "note" }, "The report is kept on the server for one hour. Download it to keep it, or to send it to the researcher.")
  ]);
}

// ---- choosing the package --------------------------------------------------------

// Every file under a dropped folder (DataTransfer entries; readEntries
// returns at most about 100 entries per call, so it is called until empty).
// A file or folder the browser cannot open is kept with its error, for
// unreadableFiles().
async function filesFromEntry(entry, out) {
  const path = entry.fullPath.replace(/^\/+/, "");
  if (entry.isFile) {
    try {
      out.push({ file: await new Promise((res, rej) => entry.file(res, rej)), path });
    } catch (e) {
      out.push({ file: null, path, error: e });
    }
  } else if (entry.isDirectory) {
    const reader = entry.createReader();
    for (;;) {
      let batch;
      try {
        batch = await new Promise((res, rej) => reader.readEntries(res, rej));
      } catch (e) {
        out.push({ file: null, path: path + "/", error: e });
        break;
      }
      if (!batch.length) break;
      for (const child of batch) await filesFromEntry(child, out);
    }
  }
}

function setup(section) {
  const drop = section.querySelector(".drop");
  const text = drop.querySelector(".drop-text");
  const button = section.querySelector("button.go");
  const pickFolder = drop.querySelector(".pick-folder");
  const pickZip = drop.querySelector(".pick-zip");
  const urlInput = section.querySelector(".repo-url");
  let chosen = null;   // { zip: File }, { files: [{file, path}], name } or { url }
  let serverReady = false;

  function reset() {
    chosen = null;
    button.disabled = true;
    drop.classList.remove("has-file");
    text.textContent = "Drop a folder or a .zip file here";
  }
  function ready() { button.disabled = !(chosen && serverReady) || busy; }

  // A link replaces a chosen folder or .zip, and the other way round.
  urlInput.addEventListener("input", () => {
    const url = urlInput.value.trim();
    if (url) {
      reset();
      section.querySelector(".status").hidden = true;
      chosen = { url };
      ready();
    } else if (chosen && chosen.url) {
      reset();
    }
  });

  function chooseZip(file) {
    reset();
    urlInput.value = "";
    if (!/\.zip$/i.test(file.name)) { statusArea(section).error("Choose a folder or a .zip file."); return; }
    if (file.size > LIMITS.zip) {
      statusArea(section).error("This .zip file is " + sizeText(file.size) + "; the limit is 500 MB." + TOO_LARGE_ADVICE);
      return;
    }
    section.querySelector(".status").hidden = true;
    chosen = { zip: file };
    text.textContent = file.name + " (" + sizeText(file.size) + ")";
    drop.classList.add("has-file");
    ready();
  }

  async function chooseFiles(files) {
    reset();
    urlInput.value = "";
    if (!files.length) { statusArea(section).error("The folder has no files."); return; }
    const total = files.reduce((s, f) => s + (f.file ? f.file.size : 0), 0);
    if (files.length > LIMITS.files) {
      statusArea(section).error("The folder has " + files.length + " files; the limit is 20,000. A version control folder (.git) can hold many: leave it out, the check will still tell you to.");
      return;
    }
    if (total > LIMITS.unpacked) {
      statusArea(section).error("The folder holds " + sizeText(total) + "; the limit is 1000 MB." + TOO_LARGE_ADVICE);
      return;
    }
    const ui = statusArea(section);
    ui.progress(0, "Checking that every file can be read…");
    text.textContent = "Reading the folder…";
    const bad = await unreadableFiles(files, f => ui.progress(f, "Checking that every file can be read: " + Math.round(f * 100) + "%"));
    if (bad.length) {
      reset();
      ui.error(unreadableMessage(bad, files.length));
      return;
    }
    section.querySelector(".status").hidden = true;
    const tops = new Set(files.map(f => f.path.split("/")[0]));
    const name = tops.size === 1 && files.every(f => f.path.includes("/")) ? [...tops][0] : "package";
    chosen = { files, name };
    text.textContent = name + ": " + files.length + " files, " + sizeText(total);
    drop.classList.add("has-file");
    ready();
  }

  pickZip.addEventListener("change", () => { if (pickZip.files[0]) chooseZip(pickZip.files[0]); });
  pickFolder.addEventListener("change", () => {
    chooseFiles([...pickFolder.files].map(file => ({ file, path: file.webkitRelativePath || file.name })))
      .catch(err => { reset(); statusArea(section).error("The folder could not be read: " + (err.message || err)); });
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
    if (entries.length === 1 && entries[0].isFile && /\.zip$/i.test(entries[0].name)) { chooseZip(loose[0]); return; }
    if (!entries.length) { if (loose.length === 1) chooseZip(loose[0]); return; }
    text.textContent = "Reading the folder…";
    try {
      const out = [];
      for (const entry of entries) await filesFromEntry(entry, out);
      await chooseFiles(out);
    } catch (err) {
      reset();
      statusArea(section).error("The folder could not be read: " + (err.message || err));
    }
  });

  button.addEventListener("click", async () => {
    if (!chosen || busy) return;
    const c = chosen;
    const fields = {};
    const people = section.querySelector("input[name=people]:checked").value;
    if (people) fields.human_participants = people;
    fields.run_code = section.querySelector("input.run-code").checked ? "true" : "false";
    const ui = statusArea(section);
    busy = true;
    ready();
    try {
      let file = null, filename = null, name;
      if (c.url) {
        fields.url = c.url;
        name = c.url.replace(/^https?:\/\//i, "").replace(/[\/?#]+$/, "").split("/").filter(Boolean).slice(-1)[0] || "repository";
      } else if (c.zip) {
        file = c.zip; filename = c.zip.name; name = baseName(c.zip.name);
      } else {
        const zip = new JSZip();
        for (const f of c.files) zip.file(f.path, f.file, { date: new Date(f.file.lastModified || Date.now()) });
        ui.progress(0, "Packing the folder…");
        try {
          file = await zip.generateAsync(
            { type: "blob", compression: "DEFLATE", compressionOptions: { level: 1 } },
            meta => ui.progress(meta.percent / 100, "Packing the folder: " + Math.round(meta.percent) + "%"));
        } catch (err) {
          // a file changed since it was chosen, or the browser ran out of memory
          const bad = await unreadableFiles(c.files, () => {});
          if (bad.length) { ui.error(unreadableMessage(bad, c.files.length)); return; }
          throw new Error("The browser could not pack the folder (" + (err.message || err) + "). Choose the folder again; if that does not help, pack it into a .zip yourself and choose the .zip.");
        }
        if (file.size > LIMITS.zip) throw new Error("The packed folder is " + sizeText(file.size) + "; the limit is 500 MB." + TOO_LARGE_ADVICE);
        filename = c.name + ".zip"; name = c.name;
      }
      offerReport(ui, await runJob(file, filename, fields, ui), name);
    } catch (e) {
      ui.error(e.message || String(e));
    } finally {
      busy = false;
      ready();
    }
  });

  // Is the check installed on the server?
  const note = section.querySelector(".server-note");
  note.textContent = "Checking the server " + API + "…";
  fetch(API + "/modules", { cache: "no-store" })
    .then(r => { if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
    .then(m => {
      const installed = Array.isArray(m.installed) ? m.installed.map(x => x.name) : [];
      if (installed.includes(MODULE)) {
        serverReady = true;
        note.textContent = "Server: " + API;
      } else {
        note.textContent = "The server " + API + " does not offer the TU/e data manager check (yet): its administrator must install the module " + MODULE + ".";
        note.classList.add("warning");
      }
      ready();
    })
    .catch(e => {
      note.textContent = "The server " + API + " could not be reached (" + (e.message || e) + "). It may be down, or it may not allow pages from this website.";
      note.classList.add("warning");
    });

  window.addEventListener("beforeunload", e => { if (busy) { e.preventDefault(); e.returnValue = ""; } });
}

setup(document.getElementById("tool-package"));
fetch(API + "/health").then(r => r.json()).then(h => {
  if (h.metacheck_version) document.getElementById("version").textContent = "Server: metacheck " + h.metacheck_version + ".";
}).catch(() => {});
