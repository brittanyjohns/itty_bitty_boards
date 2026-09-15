import { Controller } from "@hotwired/stimulus"
import { quadToMatrix3d, targetSize, isClockwiseConvex } from "../src/scene/homography"

// Connects to data-controller="scene-calibrator"
//
// The slot editor for a SceneTemplate. Ported from speakanyway-printables'
// calibrate-mockup-scene.html (click four corners, copy the quad) and grown to
// handle several slots, draggable corners, and a LIVE PREVIEW.
//
// The preview is the point. A quad drawn flat on the photo can look right and
// be 20-40px off once art is warped onto it (see board-printables-etsy.md), so
// each slot shows a numbered checkerboard warped by the same homography the
// Grover render uses, with the front layer drawn over it — exactly what the
// render will composite.
//
// Everything lays out in the base image's own pixels inside a scaled stage, so
// corner coordinates are always in the space the server validates.
export default class extends Controller {
  static targets = ["stage", "scaler", "art", "svg", "front", "list", "output", "preview"]
  static values = {
    slots: Array,
    width: Number,
    height: Number,
    kinds: Array,
    orientations: Array,
    accepts: Array,
    finishes: Array,
  }

  connect() {
    this.slots = (this.slotsValue || []).map((slot) => this.normalize(slot))
    this.active = this.slots.length ? 0 : -1
    this.drag = null
    this.onMove = this.pointerMove.bind(this)
    this.onUp = this.pointerUp.bind(this)

    this.resizeObserver = new ResizeObserver(() => this.layout())
    this.resizeObserver.observe(this.stageTarget)

    this.layout()
    this.renderList()
    this.renderStage()
  }

  disconnect() {
    this.resizeObserver?.disconnect()
    window.removeEventListener("pointermove", this.onMove)
    window.removeEventListener("pointerup", this.onUp)
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  addSlot() {
    const w = this.widthValue
    const h = this.heightValue
    const x0 = Math.round(w * 0.3)
    const x1 = Math.round(w * 0.7)
    const y0 = Math.round(h * 0.3)
    const y1 = Math.round(h * 0.7)
    let n = this.slots.length + 1
    while (this.slots.some((slot) => slot.key === `slot${n}`)) n += 1

    this.slots.push(this.normalize({
      key: `slot${n}`,
      label: `Slot ${n}`,
      quad: [[x0, y0], [x1, y0], [x1, y1], [x0, y1]],
    }))
    this.active = this.slots.length - 1
    this.renderList()
    this.renderStage()
  }

  removeSlot(event) {
    const index = Number(event.currentTarget.dataset.index)
    this.slots.splice(index, 1)
    this.active = Math.min(this.active, this.slots.length - 1)
    this.renderList()
    this.renderStage()
  }

  selectSlot(event) {
    const index = Number(event.currentTarget.dataset.index)
    if (Number.isNaN(index) || index === this.active) return
    this.active = index
    this.renderList()
    this.renderStage()
  }

  togglePreview() {
    this.renderStage()
  }

  editField(event) {
    const input = event.currentTarget
    const slot = this.slots[Number(input.dataset.index)]
    if (!slot) return
    const field = input.dataset.field

    if (field === "accepts") {
      const value = input.dataset.value
      slot.accepts = input.checked
        ? [...new Set([...slot.accepts, value])]
        : slot.accepts.filter((v) => v !== value)
    } else if (field === "corner") {
      const n = Number(input.value)
      if (!Number.isFinite(n)) return
      slot.quad[Number(input.dataset.corner)][Number(input.dataset.axis)] = Math.round(n)
    } else if (field === "bleed_px") {
      slot.bleed_px = Math.max(0, Number(input.value) || 0)
    } else {
      slot[field] = input.value
    }

    this.renderStage()
    this.updateReadouts()
  }

  // ── Dragging ─────────────────────────────────────────────────────────────

  pointerDown(event) {
    const handle = event.target.closest("[data-drag]")
    if (!handle) return
    event.preventDefault()

    const index = Number(handle.dataset.index)
    const point = this.toImage(event)
    this.drag = {
      index,
      corner: handle.dataset.drag === "corner" ? Number(handle.dataset.corner) : null,
      start: point,
      quad: this.slots[index].quad.map((pt) => [...pt]),
    }
    if (this.active !== index) {
      this.active = index
      this.renderList()
    }
    window.addEventListener("pointermove", this.onMove)
    window.addEventListener("pointerup", this.onUp)
  }

  pointerMove(event) {
    if (!this.drag) return
    const point = this.toImage(event)
    const slot = this.slots[this.drag.index]

    if (this.drag.corner !== null) {
      slot.quad[this.drag.corner] = point
    } else {
      // Whole-quad move, clamped so no corner leaves the image.
      const xs = this.drag.quad.map((pt) => pt[0])
      const ys = this.drag.quad.map((pt) => pt[1])
      const dx = this.clamp(point[0] - this.drag.start[0], -Math.min(...xs), this.widthValue - Math.max(...xs))
      const dy = this.clamp(point[1] - this.drag.start[1], -Math.min(...ys), this.heightValue - Math.max(...ys))
      slot.quad = this.drag.quad.map(([x, y]) => [Math.round(x + dx), Math.round(y + dy)])
    }

    this.renderStage()
    this.updateReadouts()
  }

  pointerUp() {
    this.drag = null
    window.removeEventListener("pointermove", this.onMove)
    window.removeEventListener("pointerup", this.onUp)
  }

  // ── Rendering ────────────────────────────────────────────────────────────

  layout() {
    const scale = this.stageTarget.clientWidth / this.widthValue
    this.scale = scale > 0 ? scale : 1
    this.scalerTarget.style.transform = `scale(${this.scale})`
    this.renderStage()
  }

  renderStage() {
    if (!this.hasSvgTarget) return
    this.outputTarget.value = JSON.stringify(this.slots)

    const preview = !this.hasPreviewTarget || this.previewTarget.checked
    this.artTarget.innerHTML = ""
    if (this.hasFrontTarget) this.frontTarget.style.display = preview ? "block" : "none"

    if (preview) {
      this.slots.forEach((slot, index) => {
        const warped = this.checkerboardFor(slot, index)
        if (warped) this.artTarget.appendChild(warped)
      })
    }

    const handleRadius = 7 / (this.scale || 1)
    const stroke = 2 / (this.scale || 1)
    const svg = this.slots.map((slot, index) => {
      const active = index === this.active
      const colour = active ? "#e6007a" : "#6366f1"
      const points = slot.quad.map(([x, y]) => `${x},${y}`).join(" ")
      const [lx, ly] = slot.quad[0]
      const corners = slot.quad.map(([x, y], corner) => `
        <circle cx="${x}" cy="${y}" r="${handleRadius}" fill="${colour}" stroke="#fff" stroke-width="${stroke}"
                style="cursor: grab" data-drag="corner" data-index="${index}" data-corner="${corner}"></circle>
        <text x="${x + handleRadius * 1.6}" y="${y - handleRadius * 1.2}" font-size="${12 / this.scale}"
              fill="#fff" stroke="#000" stroke-width="${0.5 / this.scale}" style="pointer-events:none">${["TL", "TR", "BR", "BL"][corner]}</text>`).join("")

      return `
        <polygon points="${points}" fill="${active ? "rgba(230,0,122,0.08)" : "rgba(99,102,241,0.05)"}"
                 stroke="${colour}" stroke-width="${stroke}" style="cursor: move"
                 data-drag="move" data-index="${index}"></polygon>
        <text x="${lx}" y="${ly - handleRadius * 2.5}" font-size="${14 / this.scale}" font-weight="600"
              fill="${colour}" style="pointer-events:none">${this.escape(slot.key)}</text>
        ${active ? corners : slot.quad.map(([x, y], corner) => `
          <circle cx="${x}" cy="${y}" r="${handleRadius * 0.7}" fill="${colour}"
                  style="cursor: grab" data-drag="corner" data-index="${index}" data-corner="${corner}"></circle>`).join("")}`
    }).join("")

    this.svgTarget.innerHTML = svg
  }

  // A numbered checkerboard at the quad's own proportions, warped by the same
  // matrix the render uses. Numbers make a flipped or rotated quad obvious in a
  // way a plain grid is not.
  checkerboardFor(slot, index) {
    const { width, height } = targetSize(slot.quad)
    if (!(width > 0 && height > 0) || !isClockwiseConvex(slot.quad)) return null

    let matrix
    try {
      matrix = quadToMatrix3d(width, height, slot.quad)
    } catch (_e) {
      return null
    }

    const cols = 6
    const rows = Math.max(2, Math.round(cols / (width / height)))
    const el = document.createElement("div")
    el.style.cssText = `position:absolute;top:0;left:0;width:${width}px;height:${height}px;` +
      `transform-origin:0 0;transform:${matrix};display:grid;opacity:0.88;` +
      `grid-template-columns:repeat(${cols},1fr);grid-template-rows:repeat(${rows},1fr);pointer-events:none;`

    const size = Math.max(10, Math.round(Math.min(width / cols, height / rows) * 0.4))
    for (let r = 0; r < rows; r += 1) {
      for (let c = 0; c < cols; c += 1) {
        const cell = document.createElement("div")
        const dark = (r + c) % 2 === 0
        cell.style.cssText = `background:${dark ? (index === this.active ? "#e6007a" : "#1f2937") : "#ffffff"};` +
          `color:${dark ? "#ffffff" : "#1f2937"};display:flex;align-items:center;justify-content:center;` +
          `font:600 ${size}px system-ui,sans-serif;`
        cell.textContent = String(r * cols + c + 1)
        el.appendChild(cell)
      }
    }
    return el
  }

  renderList() {
    if (!this.hasListTarget) return
    if (this.slots.length === 0) {
      this.listTarget.innerHTML = `<p class="text-xs text-t3">No slots yet. Add one, then drag its corners onto a blank surface in the photo.</p>`
      return
    }

    const select = (index, field, options, value) => `
      <select data-index="${index}" data-field="${field}" data-action="change->scene-calibrator#editField"
              class="admin-input border rounded px-2 py-1 text-xs">
        ${options.map((opt) => `<option value="${this.escape(opt)}" ${opt === value ? "selected" : ""}>${this.escape(opt)}</option>`).join("")}
      </select>`

    this.listTarget.innerHTML = this.slots.map((slot, index) => `
      <div class="admin-card border rounded-lg p-3 mb-3 ${index === this.active ? "ring-2 ring-pink-500" : ""}"
           data-index="${index}" data-action="click->scene-calibrator#selectSlot">
        <div class="flex items-center justify-between mb-2">
          <span class="text-xs font-medium text-t1">Slot ${index + 1}</span>
          <button type="button" class="text-[11px] text-red-500 hover:underline"
                  data-index="${index}" data-action="click->scene-calibrator#removeSlot">Remove</button>
        </div>
        <div class="grid grid-cols-2 gap-2 text-xs mb-2">
          <label class="text-t2">Key
            <input type="text" value="${this.escape(slot.key)}" data-index="${index}" data-field="key"
                   data-action="input->scene-calibrator#editField" class="admin-input border rounded px-2 py-1 w-full" />
          </label>
          <label class="text-t2">Label
            <input type="text" value="${this.escape(slot.label)}" data-index="${index}" data-field="label"
                   data-action="input->scene-calibrator#editField" class="admin-input border rounded px-2 py-1 w-full" />
          </label>
          <label class="text-t2">Kind ${select(index, "kind", this.kindsValue, slot.kind)}</label>
          <label class="text-t2">Orientation ${select(index, "orientation", this.orientationsValue, slot.orientation)}</label>
          <label class="text-t2">Finish ${select(index, "finish", this.finishesValue, slot.finish)}</label>
          <label class="text-t2">Bleed px
            <input type="number" min="0" max="20" value="${slot.bleed_px}" data-index="${index}" data-field="bleed_px"
                   data-action="input->scene-calibrator#editField" class="admin-input border rounded px-2 py-1 w-20" />
          </label>
        </div>
        <div class="text-xs text-t2 mb-2">Accepts:
          ${this.acceptsValue.map((value) => `
            <label class="mr-2"><input type="checkbox" ${slot.accepts.includes(value) ? "checked" : ""}
              data-index="${index}" data-field="accepts" data-value="${this.escape(value)}"
              data-action="change->scene-calibrator#editField" /> ${this.escape(value)}</label>`).join("")}
        </div>
        <div class="grid grid-cols-4 gap-1 text-[11px] text-t3 mb-1">
          ${slot.quad.map((pt, corner) => `
            <div>${["TL", "TR", "BR", "BL"][corner]}
              ${[0, 1].map((axis) => `<input type="number" value="${pt[axis]}" data-index="${index}" data-field="corner"
                 data-corner="${corner}" data-axis="${axis}" data-action="input->scene-calibrator#editField"
                 class="admin-input border rounded px-1 py-0.5 w-full" />`).join("")}
            </div>`).join("")}
        </div>
        <p class="text-[11px] text-t3" data-readout="${index}"></p>
      </div>`).join("")

    this.updateReadouts()
  }

  // Updates the per-slot numbers in place — rebuilding the list mid-drag would
  // steal focus from whatever field the admin is typing in.
  updateReadouts() {
    if (!this.hasListTarget) return
    this.slots.forEach((slot, index) => {
      const card = this.listTarget.querySelector(`[data-readout="${index}"]`)
      if (card) card.innerHTML = this.readout(slot)

      this.listTarget.querySelectorAll(`input[data-field="corner"][data-index="${index}"]`).forEach((input) => {
        if (input === document.activeElement) return
        input.value = slot.quad[Number(input.dataset.corner)][Number(input.dataset.axis)]
      })
    })
  }

  readout(slot) {
    const { width, height } = targetSize(slot.quad)
    if (!(width > 0 && height > 0)) return `<span class="text-red-500">Corners are coincident.</span>`
    const aspect = width / height
    const shape = aspect > 1 ? "landscape" : "portrait"
    const problems = []
    if (!isClockwiseConvex(slot.quad)) problems.push("corners must go clockwise from top-left and not cross")
    if (slot.orientation !== "any" && slot.orientation !== shape) problems.push(`the quad is ${shape}, not ${slot.orientation}`)
    if (slot.accepts.length === 0) problems.push("pick at least one art source")

    return `${width}×${height} · aspect ${aspect.toFixed(2)} (${shape})` +
      (problems.length ? ` · <span class="text-red-500">${this.escape(problems.join("; "))}</span>` : "")
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  normalize(slot) {
    const kind = slot.kind || "paper"
    return {
      key: slot.key || "",
      label: slot.label || "",
      kind,
      quad: (slot.quad || [[0, 0], [10, 0], [10, 10], [0, 10]]).map((pt) => [Number(pt[0]), Number(pt[1])]),
      orientation: slot.orientation || "any",
      accepts: Array.isArray(slot.accepts) ? [...slot.accepts] : [...this.acceptsValue],
      finish: slot.finish || (kind === "tablet" ? "glare" : "shadow"),
      bleed_px: Number(slot.bleed_px) || 0,
    }
  }

  toImage(event) {
    const rect = this.stageTarget.getBoundingClientRect()
    const x = ((event.clientX - rect.left) / rect.width) * this.widthValue
    const y = ((event.clientY - rect.top) / rect.height) * this.heightValue
    return [Math.round(this.clamp(x, 0, this.widthValue)), Math.round(this.clamp(y, 0, this.heightValue))]
  }

  clamp(n, min, max) {
    return Math.min(Math.max(n, min), max)
  }

  escape(value) {
    return String(value ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
  }
}
