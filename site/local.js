// local.js: the texts of the metacheck Docker installation
// (scienceverse/metacheck_platform_docker), which runs this website on the
// user's own computer. A page marks a text for this server with the class
// "server-only" and its version for the user's own computer with
// "local-only"; when the web interface says it runs in that installation
// (GET /api/health, local: true), the page shows the second. Within those,
// an element with data-when="grobid-remote llm-mistral" (for example) is shown
// only when every word matches the installation: grobid-local or
// grobid-remote (where PDFs are converted), llm-ollama, llm-mistral or
// llm-none (the model of the power check). Loaded in the page's <head>, so
// these texts are hidden before the page is shown.
(function () {
  const style = document.createElement("style");
  style.textContent =
    ".local-only, [data-when] { display: none !important; }" +
    "html.local .server-only { display: none !important; }" +
    "html.local .local-only, html.local [data-when].when-on { display: revert !important; }";
  document.head.appendChild(style);
  const root = document.documentElement;
  const apply = () => {
    for (const el of document.querySelectorAll("[data-when]")) {
      const on = el.dataset.when.split(/\s+/).every(c => root.classList.contains(c));
      el.classList.toggle("when-on", on);
    }
  };
  fetch("/api/health", { cache: "no-store" })
    .then(r => r.json())
    .then(h => {
      if (h.local !== true) return;
      root.classList.add("local", "grobid-" + (h.grobid || "none"), "llm-" + (h.llm || "none"));
      if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", apply);
      else apply();
    })
    .catch(() => {});
})();
