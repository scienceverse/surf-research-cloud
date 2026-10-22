// The metacheck server this page sends packages to: on the SURF server it is
// the server the page comes from (its web interface at /api). Copied from
// Lakens/tue_datamanager_check (web/), where this file names the SURF server's
// full address so the page can be served from anywhere.
window.TDC_API = location.origin + "/api";
