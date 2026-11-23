// Our own menus and dialogs in the app's theme (shared by both windows).
import { ICONS } from "./playback.ts";
import { LIKED, library, newAlbum, toggleInAlbum } from "./library.ts";

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
let open: HTMLElement | null = null;

export function closePopup() { open?.remove(); open = null; }

function place(card: HTMLElement, anchor: DOMRect) {
  document.body.appendChild(card);
  const w = card.offsetWidth, h = card.offsetHeight;
  const x = Math.min(innerWidth - w - 10, Math.max(10, anchor.right - w));
  const y = anchor.bottom + 6 + h > innerHeight - 10 ? Math.max(10, anchor.top - h - 6) : anchor.bottom + 6;
  card.style.left = `${x}px`; card.style.top = `${y}px`;
}

function shield(onClose = closePopup) {
  const s = document.createElement("div");
  s.className = "shield";
  s.onclick = onClose;
  return s;
}

export interface MenuItem { icon: string; label: string; danger?: boolean; action: () => void }

/** A menu under `anchor`. */
export function menu(anchor: HTMLElement, items: MenuItem[]) {
  closePopup();
  const wrap = document.createElement("div");
  wrap.className = "popup-root";
  const card = document.createElement("div");
  card.className = "menu-card";
  for (const it of items) {
    if (it.label === "-") { card.insertAdjacentHTML("beforeend", `<div class="menu-div"></div>`); continue; }
    const b = document.createElement("button");
    b.className = "menu-row" + (it.danger ? " danger" : "");
    b.innerHTML = `<span class="mi">${it.icon}</span><span>${esc(it.label)}</span>`;
    b.onclick = (e) => { e.stopPropagation(); closePopup(); it.action(); };
    card.appendChild(b);
  }
  wrap.append(shield());
  open = wrap;
  document.body.appendChild(wrap);
  place(card, anchor.getBoundingClientRect());
  wrap.appendChild(card);
}

/** "Add to album": create new (with the song in it) first, then every album with a checkbox. */
export function albumPicker(anchor: HTMLElement | DOMRect, songID: string, onDone?: () => void) {
  closePopup();
  const wrap = document.createElement("div");
  wrap.className = "popup-root";
  const card = document.createElement("div");
  card.className = "menu-card picker";
  const draw = () => {
    card.innerHTML = `<div class="menu-head">ADD TO ALBUM</div>
      <button class="menu-row" data-new><span class="mi">${ICONS.plus}</span><span>Create new album</span></button>
      <div class="menu-div"></div>` +
      library.albums.map((a) => `<button class="menu-row check" data-id="${a.id}">
        <span class="box ${a.songIDs.includes(songID) ? "on" : ""}">${a.songIDs.includes(songID) ? ICONS.check : ""}</span>
        <span class="mi">${a.id === LIKED ? ICONS.heartFill : ICONS.library}</span><span>${esc(a.name)}</span></button>`).join("");
    card.querySelector("[data-new]")!.addEventListener("click", (e) => {
      e.stopPropagation();
      const row = card.querySelector("[data-new]") as HTMLElement;
      row.outerHTML = `<div class="new-row"><input placeholder="New album name" autofocus><button>${ICONS.plus}</button></div>`;
      const input = card.querySelector(".new-row input") as HTMLInputElement;
      input.focus();
      const create = async () => { if (input.value.trim()) { await newAlbum(input.value.trim(), songID); closePopup(); onDone?.(); } };
      input.onkeydown = (k) => { if (k.key === "Enter") create(); };
      (card.querySelector(".new-row button") as HTMLElement).onclick = create;
    });
    card.querySelectorAll<HTMLElement>("[data-id]").forEach((row) =>
      row.addEventListener("click", async (e) => { e.stopPropagation(); await toggleInAlbum(songID, row.dataset.id!); draw(); onDone?.(); }));
  };
  draw();
  wrap.append(shield());
  open = wrap;
  document.body.appendChild(wrap);
  place(card, anchor instanceof HTMLElement ? anchor.getBoundingClientRect() : anchor);
  wrap.appendChild(card);
}

/** A centered dialog with a text field (new album, rename, edit). */
export function prompt(title: string, fields: { label: string; value: string }[], action: string, done: (values: string[]) => void, note?: string) {
  closePopup();
  const wrap = document.createElement("div");
  wrap.className = "popup-root dim";
  wrap.innerHTML = `<div class="dialog"><div class="dlg-title">${esc(title)}</div>${note ? `<div class="dlg-note">${esc(note)}</div>` : ""}
    ${fields.map((f) => `<input class="field" placeholder="${esc(f.label)}" value="${esc(f.value)}">`).join("")}
    <div class="dlg-buttons"><button class="btn plain">Cancel</button><button class="btn primary">${esc(action)}</button></div></div>`;
  wrap.prepend(shield());
  open = wrap;
  document.body.appendChild(wrap);
  const inputs = [...wrap.querySelectorAll<HTMLInputElement>(".field")];
  inputs[0]?.focus();
  const ok = () => { const v = inputs.map((i) => i.value.trim()); if (v[0]) { closePopup(); done(v); } };
  (wrap.querySelector(".btn.plain") as HTMLElement).onclick = closePopup;
  (wrap.querySelector(".btn.primary") as HTMLElement).onclick = ok;
  inputs.forEach((i) => (i.onkeydown = (k) => { if (k.key === "Enter") ok(); }));
}

/** A centered yes/no dialog. */
export function confirm(title: string, message: string, action: string, done: () => void) {
  closePopup();
  const wrap = document.createElement("div");
  wrap.className = "popup-root dim";
  wrap.innerHTML = `<div class="dialog"><div class="dlg-title">${esc(title)}</div><div class="dlg-note">${esc(message)}</div>
    <div class="dlg-buttons"><button class="btn plain">Cancel</button><button class="btn danger">${esc(action)}</button></div></div>`;
  wrap.prepend(shield());
  open = wrap;
  document.body.appendChild(wrap);
  (wrap.querySelector(".btn.plain") as HTMLElement).onclick = closePopup;
  (wrap.querySelector(".btn.danger") as HTMLElement).onclick = () => { closePopup(); done(); };
}

/** A notice in the middle that floats away after 3 seconds. */
export function notice(title: string, detail = "") {
  const n = document.createElement("div");
  n.className = "notice";
  n.innerHTML = `<div class="notice-check">${ICONS.check}</div><b>${esc(title)}</b>${detail ? `<small>${esc(detail)}</small>` : ""}`;
  document.body.appendChild(n);
  setTimeout(() => n.classList.add("leaving"), 3000);
  setTimeout(() => n.remove(), 3400);
}
