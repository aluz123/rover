// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
// A faithful web replica of Rover's search panel, fed by real engine output (data.js). Used by the website and the launch films.
(function () {
  const KIND_COLOR = { pdf: "#F2534C", key: "#3D8BFF", pptx: "#E8643A", numbers: "#2DBE6C", xlsx: "#22A35A", pages: "#FF9F2E",
    docx: "#3B6FE0", heic: "#B26BFF", jpg: "#B26BFF", png: "#9C7BFF", svg: "#FF7AB6", mov: "#4B4F63", mp4: "#4B4F63",
    md: "#8A8FA3", m4a: "#FF4F8B", zip: "#A88A5A", dmg: "#7D8597", tsx: "#3178C6", h: "#6E7681", py: "#3572A5" };

  const esc = s => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const ext = n => (n.includes(".") ? n.split(".").pop().toLowerCase() : "");

  function fileIcon(h, size = 30) {
    if (h.dir) {
      return `<svg width="${size}" height="${size}" viewBox="0 0 32 32"><path d="M3 8.5a2.5 2.5 0 0 1 2.5-2.5h7l2.6 2.6H26.5A2.5 2.5 0 0 1 29 11.1V24a2.5 2.5 0 0 1-2.5 2.5h-21A2.5 2.5 0 0 1 3 24z" fill="#4AA8FF"/><path d="M3 12h26v12a2.5 2.5 0 0 1-2.5 2.5h-21A2.5 2.5 0 0 1 3 24z" fill="#6BBBFF"/></svg>`;
    }
    const e = ext(h.name), c = KIND_COLOR[e] || "#8A8FA3", lab = e.slice(0, 4).toUpperCase();
    return `<svg width="${size}" height="${size}" viewBox="0 0 32 32"><path d="M7 2.5h12.5L26 9v19a1.5 1.5 0 0 1-1.5 1.5h-17A1.5 1.5 0 0 1 6 28V4a1.5 1.5 0 0 1 1-1.5z" fill="#F4F5F8"/><path d="M19.5 2.5V8a1 1 0 0 0 1 1H26z" fill="#D5D8E0"/>
      <rect x="4" y="17" width="${Math.max(14, lab.length * 5 + 6)}" height="9" rx="2" fill="${c}"/><text x="${4 + Math.max(14, lab.length * 5 + 6) / 2}" y="23.7" font-size="6.2" font-weight="800" fill="#fff" text-anchor="middle" font-family="-apple-system,Geist,sans-serif">${lab}</text></svg>`;
  }

  // Previews are drawn, not real files: the demo home has no contents.
  function preview(h) {
    if (!h) return `<div class="rv-pv-empty">No selection</div>`;
    const e = ext(h.name);
    let art;
    if (h.dir) art = `<div class="rv-art rv-art-folder">${fileIcon(h, 120)}</div>`;
    else if (["key", "pptx"].includes(e) || /deck|pitch/i.test(h.name)) art = `<div class="rv-art rv-art-slide"><div class="rv-slide"><div class="rv-slide-k">NORTHWIND</div><div class="rv-slide-t">The operating system<br>for small fleets</div><div class="rv-slide-b"><span></span><span></span><span></span></div></div></div>`;
    else if (["heic", "jpg", "png"].includes(e)) {
      const seed = [...h.name].reduce((a, c) => a + c.charCodeAt(0), 0);
      const hue = /screenshot/i.test(h.name) ? 230 : (seed * 37) % 360;
      art = /screenshot/i.test(h.name)
        ? `<div class="rv-art rv-art-shot"><div class="rv-shot"><i></i><i></i><i></i><b></b><b></b><b></b></div></div>`
        : `<div class="rv-art rv-art-photo" style="--h:${hue}"><div class="rv-sun"></div><div class="rv-hill a"></div><div class="rv-hill b"></div><div class="rv-roofs"></div></div>`;
    } else if (["mov", "mp4"].includes(e)) art = `<div class="rv-art rv-art-video"><div class="rv-play"></div><div class="rv-scrub"><span></span></div></div>`;
    else if (["numbers", "xlsx"].includes(e)) art = `<div class="rv-art rv-art-doc"><div class="rv-sheet">${Array.from({ length: 30 }, (_, i) => `<i style="opacity:${(i % 5 === 0) ? 1 : .55}"></i>`).join("")}</div></div>`;
    else art = `<div class="rv-art rv-art-doc"><div class="rv-page"><b></b>${Array.from({ length: 11 }, (_, i) => `<i style="width:${[92, 88, 95, 70, 0, 90, 84, 93, 60, 0, 80][i]}%"></i>`).join("")}</div></div>`;
    return `${art}<div class="rv-pv-meta"><div class="rv-pv-name">${esc(h.name)}</div>
      <div class="rv-pv-row"><span>Kind</span><b>${esc(h.dir ? "Folder" : h.kind)}</b></div>
      <div class="rv-pv-row"><span>Size</span><b>${esc(h.size)}</b></div>
      <div class="rv-pv-row"><span>Modified</span><b>${esc(h.when)}</b></div>
      <div class="rv-pv-row"><span>Where</span><b>${esc(h.folder)}</b></div></div>`;
  }

  function hint(k, l) { return `<span class="rv-hint"><kbd>${k}</kbd>${l}</span>`; }

  class Panel {
    constructor(el, opts = {}) {
      this.el = el; this.opts = Object.assign({ preview: true, stats: "225,066 files · 2 ms" }, opts);
      el.classList.add("rv-panel");
      el.innerHTML = `
        <div class="rv-head"><svg class="rv-glass" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="10.5" cy="10.5" r="6.5"/><path d="m20 20-4.6-4.6"/></svg>
          <span class="rv-badge"></span><div class="rv-field"><span class="rv-text"></span><span class="rv-caret"></span><span class="rv-ph">Find anything…</span></div></div>
        <div class="rv-chips"></div>
        <div class="rv-body"><div class="rv-list"></div>${this.opts.preview ? `<div class="rv-pv"></div>` : ""}</div>
        <div class="rv-foot"><span class="rv-stats"></span><span class="rv-sp"></span>
          ${hint("↩", "open")}${hint("⌘↩", "show in Finder")}${hint("⌘M", "move")}${hint("space", "preview")}${hint("⇥", "ask")}</div>`;
      this.$ = s => el.querySelector(s);
      this.query = ""; this.sel = 0; this.hits = [];
      this.setStats(this.opts.stats);
    }
    setStats(s) { this.$(".rv-stats").textContent = s; }
    setMode(badge) { const b = this.$(".rv-badge"); b.textContent = badge || ""; b.style.display = badge ? "" : "none"; }
    type(text, caret = true) {
      this.query = text;
      this.$(".rv-text").textContent = text;
      this.$(".rv-ph").style.display = text ? "none" : "";
      this.$(".rv-caret").style.visibility = caret ? "visible" : "hidden";
    }
    show(result, sel = 0) {
      const data = result || { chips: [], hits: [] };
      this.hits = data.hits; this.sel = Math.min(sel, Math.max(0, this.hits.length - 1));
      this.$(".rv-chips").innerHTML = data.chips.map(c => `<span class="rv-chip">${esc(c)}</span>`).join("");
      this.$(".rv-chips").classList.toggle("on", data.chips.length > 0);
      this.$(".rv-list").innerHTML = this.hits.map((h, i) => `
        <div class="rv-row${i === this.sel ? " sel" : ""}" data-i="${i}">${fileIcon(h)}
          <div class="rv-rt"><div class="rv-name">${esc(h.name)}</div><div class="rv-path">${esc(h.folder)}</div></div>
          <div class="rv-when">${esc(h.when)}</div>${i < 9 ? `<kbd class="rv-num">⌘${i + 1}</kbd>` : ""}</div>`).join("")
        || `<div class="rv-empty">Nothing found yet</div>`;
      this.select(this.sel);
    }
    select(i) {
      this.sel = i;
      this.el.querySelectorAll(".rv-row").forEach((r, j) => r.classList.toggle("sel", j === i));
      const pv = this.$(".rv-pv"); if (pv) pv.innerHTML = preview(this.hits[i]);
    }
  }

  window.RoverUI = { Panel, fileIcon, preview, esc };
})();
