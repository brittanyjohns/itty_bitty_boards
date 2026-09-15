import { Controller } from "@hotwired/stimulus"
import { quadToMatrix3d, targetSize, isClockwiseConvex } from "../src/scene/homography"
import { fitText } from "../src/scene/text_fit"

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
// It also edits TEXT SLOTS (a box whose font, weight, colour and size range are
// set here; a mockup supplies only the words) and OVERLAY REGIONS (a box a
// fact-driven styled partial is scaled into). Both are axis-aligned boxes,
// dragged and resized unrotated; a text slot's rotation is applied to its
// preview about the box's centre, as the render does. Both draw above the front
// layer, again as the render does.
//
// Everything lays out in the base image's own pixels inside a scaled stage, so
// corner and box coordinates are always in the space the server validates.
const TEXT_NUMERIC_FIELDS = ["rotation", "weight", "max_px", "min_px", "max_chars"]
const MIN_BOX_PX = 8

export default class extends Controller {
  static targets = [
    "stage", "scaler", "art", "svg", "front", "list", "output", "preview",
    "textLayer", "textOutput", "overlayOutput",
  ]

  static values = {
    slots: Array,
    textSlots: Array,
    overlayRegions: Array,
    width: Number,
    height: Number,
    kinds: Array,
    orientations: Array,
    accepts: Array,
    finishes: Array,
    fonts: Object,
    aligns: Array,
    partials: Array,
    maxChars: { type: Number, default: 280 },
  }

  connect() {
    this.slots = (this.slotsValue || []).map((slot) => this.normalize(slot))
    this.textSlots = (this.textSlotsValue || []).map((slot) => this.normalizeText(slot))
    this.overlays = (this.overlayRegionsValue || []).map((region) => this.normalizeOverlay(region))
    this.active = this.slots.length ? 0 : -1
    // { type: "text" | "overlay", index } while a box is selected, else null.
    this.boxSelection = null
    this.drag = null
    this.onMove = this.pointerMove.bind(this)
    this.onUp = this.pointerUp.bind(this)

    this.resizeObserver = new ResizeObserver(() => this.layout())
    this.resizeObserver.observe(this.stageTarget)

    this.layout()
    this.renderList()
    this.renderStage()

    // The first fit measured whatever face had loaded by then; refit once the
    // inlined faces are ready so the preview sizes real glyphs.
    if (document.fonts?.ready) document.fonts.ready.then(() => this.renderStage())
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
    while (this.allKeys().includes(`slot${n}`)) n += 1

    this.slots.push(this.normalize({
      key: `slot${n}`,
      label: `Slot ${n}`,
      quad: [[x0, y0], [x1, y0], [x1, y1], [x0, y1]],
    }))
    this.active = this.slots.length - 1
    this.boxSelection = null
    this.renderList()
    this.renderStage()
  }

  addText() {
    const w = this.widthValue
    const h = this.heightValue
    const key = this.uniqueKey("text")
    this.textSlots.push(this.normalizeText({
      key,
      label: key.replace(/(\d+)$/, " $1").replace(/^./, (c) => c.toUpperCase()),
      box: [Math.round(w * 0.2), Math.round(h * 0.06), Math.round(w * 0.6), Math.round(h * 0.14)],
      default: "Your words here",
    }))
    this.selectBoxAt("text", this.textSlots.length - 1)
  }

  addOverlay() {
    const w = this.widthValue
    const h = this.heightValue
    this.overlays.push(this.normalizeOverlay({
      key: this.uniqueKey("overlay"),
      box: [Math.round(w * 0.05), Math.round(h * 0.55), Math.round(w * 0.4), Math.round(h * 0.35)],
      partial: this.partialsValue[0],
    }))
    this.selectBoxAt("overlay", this.overlays.length - 1)
  }

  removeSlot(event) {
    event.stopPropagation()
    const index = Number(event.currentTarget.dataset.index)
    this.slots.splice(index, 1)
    this.active = Math.min(this.active, this.slots.length - 1)
    this.renderList()
    this.renderStage()
  }

  removeBox(event) {
    event.stopPropagation()
    const { type } = event.currentTarget.dataset
    this.boxList(type).splice(Number(event.currentTarget.dataset.index), 1)
    this.boxSelection = null
    this.renderList()
    this.renderStage()
  }

  selectSlot(event) {
    const index = Number(event.currentTarget.dataset.index)
    if (Number.isNaN(index) || !this.slots[index]) return
    if (index === this.active && !this.boxSelection) return
    this.active = index
    this.boxSelection = null
    this.renderList()
    this.renderStage()
  }

  selectBox(event) {
    const { type } = event.currentTarget.dataset
    const index = Number(event.currentTarget.dataset.index)
    if (this.isSelectedBox(type, index)) return
    this.selectBoxAt(type, index)
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

  editBoxField(event) {
    const input = event.currentTarget
    const { type, field } = input.dataset
    const item = this.boxList(type)[Number(input.dataset.index)]
    if (!item) return

    if (field === "box") {
      const n = Number(input.value)
      if (!Number.isFinite(n)) return
      item.box[Number(input.dataset.axis)] = Math.round(n)
    } else if (TEXT_NUMERIC_FIELDS.includes(field)) {
      const n = Number(input.value)
      if (!Number.isFinite(n)) return
      item[field] = field === "rotation" ? n : Math.round(n)
    } else {
      item[field] = input.value
    }

    // A new font has its own weight range; pull the weight into it and rebuild
    // the card so the weight input's min/max follow.
    if (type === "text" && field === "font") {
      const font = this.fontsValue[item.font]
      if (font) {
        item.weight = this.clamp(Math.round(item.weight / 100) * 100, font.min, font.max)
      }
      this.renderList()
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
    const kind = handle.dataset.drag

    if (kind === "box-move" || kind === "box-resize") {
      const { type } = handle.dataset
      const item = this.boxList(type)[index]
      if (!item) return
      this.drag = { boxType: type, index, resize: kind === "box-resize", start: point, origin: [...item.box] }
      if (!this.isSelectedBox(type, index)) {
        this.boxSelection = { type, index }
        this.active = -1
        this.renderList()
      }
    } else {
      this.drag = {
        index,
        corner: kind === "corner" ? Number(handle.dataset.corner) : null,
        start: point,
        quad: this.slots[index].quad.map((pt) => [...pt]),
      }
      if (this.active !== index || this.boxSelection) {
        this.active = index
        this.boxSelection = null
        this.renderList()
      }
    }
    window.addEventListener("pointermove", this.onMove)
    window.addEventListener("pointerup", this.onUp)
  }

  pointerMove(event) {
    if (!this.drag) return
    const point = this.toImage(event)

    if (this.drag.boxType) {
      const item = this.boxList(this.drag.boxType)[this.drag.index]
      if (!item) return
      const [x, y, w, h] = this.drag.origin
      const dx = point[0] - this.drag.start[0]
      const dy = point[1] - this.drag.start[1]
      if (this.drag.resize) {
        item.box = [
          x, y,
          Math.round(this.clamp(w + dx, MIN_BOX_PX, this.widthValue - x)),
          Math.round(this.clamp(h + dy, MIN_BOX_PX, this.heightValue - y)),
        ]
      } else {
        item.box = [
          Math.round(this.clamp(x + dx, 0, this.widthValue - w)),
          Math.round(this.clamp(y + dy, 0, this.heightValue - h)),
          w, h,
        ]
      }
    } else {
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
    if (this.hasTextOutputTarget) this.textOutputTarget.value = JSON.stringify(this.textSlots)
    if (this.hasOverlayOutputTarget) this.overlayOutputTarget.value = JSON.stringify(this.overlays)

    const preview = !this.hasPreviewTarget || this.previewTarget.checked
    this.artTarget.innerHTML = ""
    if (this.hasFrontTarget) this.frontTarget.style.display = preview ? "block" : "none"

    if (preview) {
      this.slots.forEach((slot, index) => {
        const warped = this.checkerboardFor(slot, index)
        if (warped) this.artTarget.appendChild(warped)
      })
    }

    this.renderBoxPreviews(preview)

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

    const boxes = [
      ...this.textSlots.map((item, index) => this.boxSvg("text", item, index, handleRadius, stroke)),
      ...this.overlays.map((item, index) => this.boxSvg("overlay", item, index, handleRadius, stroke)),
    ].join("")

    this.svgTarget.innerHTML = svg + boxes
  }

  // The unrotated editing box: a dashed outline to move by, a square handle at
  // the bottom-right to resize by.
  boxSvg(type, item, index, handleRadius, stroke) {
    const [x, y, w, h] = item.box
    const selected = this.isSelectedBox(type, index)
    const colour = selected ? "#e6007a" : (type === "text" ? "#0284c7" : "#16a34a")
    const dash = `${6 / this.scale} ${4 / this.scale}`
    const label = type === "text" ? item.key : `${item.key} · ${item.partial}`
    const handle = handleRadius * (selected ? 1 : 0.75)

    return `
      <rect x="${x}" y="${y}" width="${w}" height="${h}" fill="${selected ? "rgba(230,0,122,0.05)" : "rgba(0,0,0,0)"}"
            stroke="${colour}" stroke-width="${stroke}" stroke-dasharray="${dash}" style="cursor: move"
            data-drag="box-move" data-type="${type}" data-index="${index}"></rect>
      <text x="${x}" y="${y - handleRadius}" font-size="${13 / this.scale}" font-weight="600"
            fill="${colour}" style="pointer-events:none">${this.escape(label)}</text>
      <rect x="${x + w - handle}" y="${y + h - handle}" width="${handle * 2}" height="${handle * 2}"
            fill="${colour}" stroke="#fff" stroke-width="${stroke}" style="cursor: nwse-resize"
            data-drag="box-resize" data-type="${type}" data-index="${index}"></rect>`
  }

  // Text slots show their DEFAULT words in the chosen face, fitted exactly as
  // the render fits them (text_fit.js). A slot with no default shows its label,
  // faded, so the box is still visible. Overlays show a labelled placeholder:
  // their content comes from a printable's facts, and a template has none.
  renderBoxPreviews(preview) {
    if (!this.hasTextLayerTarget) return
    this.textLayerTarget.innerHTML = ""
    if (!preview) return

    this.overlays.forEach((region) => {
      const [x, y, w, h] = region.box
      const el = document.createElement("div")
      el.style.cssText = `position:absolute;left:${x}px;top:${y}px;width:${w}px;height:${h}px;` +
        "display:flex;align-items:center;justify-content:center;text-align:center;" +
        "background:rgba(207,235,218,0.55);border-radius:12px;color:#2f7d5b;" +
        `font:700 ${Math.max(12, Math.round(Math.min(w, h) / 8))}px Nunito,system-ui,sans-serif;pointer-events:none;`
      el.textContent = `${region.partial.replace(/_/g, " ")} (from the printable's facts)`
      this.textLayerTarget.appendChild(el)
    })

    this.textSlots.forEach((slot) => {
      const [x, y, w, h] = slot.box
      if (!(w > 0 && h > 0)) return

      const box = document.createElement("div")
      box.className = `scene-font-${slot.font}`
      box.style.cssText = `position:absolute;left:${x}px;top:${y}px;width:${w}px;height:${h}px;` +
        "display:flex;flex-direction:column;justify-content:center;transform-origin:50% 50%;pointer-events:none;" +
        (slot.rotation ? `transform:rotate(${slot.rotation}deg);` : "")

      const inner = document.createElement("div")
      const placeholder = !slot.default
      inner.textContent = slot.default || slot.label || slot.key
      inner.style.cssText = "display:block;width:100%;line-height:1.2;white-space:normal;" +
        `font-weight:${slot.weight};color:${slot.color};text-align:${slot.align};` +
        (placeholder ? "opacity:0.35;font-style:italic;" : "")

      box.appendChild(inner)
      this.textLayerTarget.appendChild(box)
      fitText(box, inner, slot.max_px, Math.min(slot.min_px, slot.max_px))
      if (box.hasAttribute("data-overflow")) inner.style.overflowWrap = "anywhere"
    })
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

    const slotsHtml = this.slots.length === 0
      ? `<p class="text-xs text-t3 mb-3">No slots yet. Add one, then drag its corners onto a blank surface in the photo.</p>`
      : this.slots.map((slot, index) => this.slotCard(slot, index)).join("")

    const textHtml = this.textSlots.length === 0 ? "" : `
      <h3 class="text-xs font-semibold text-t1 mt-4 mb-2">Text slots</h3>
      ${this.textSlots.map((slot, index) => this.textCard(slot, index)).join("")}`

    const overlayHtml = this.overlays.length === 0 ? "" : `
      <h3 class="text-xs font-semibold text-t1 mt-4 mb-2">Overlays</h3>
      ${this.overlays.map((region, index) => this.overlayCard(region, index)).join("")}`

    this.listTarget.innerHTML = slotsHtml + textHtml + overlayHtml
    this.updateReadouts()
  }

  slotCard(slot, index) {
    const select = (field, options, value) => `
      <select data-index="${index}" data-field="${field}" data-action="change->scene-calibrator#editField"
              class="admin-input border rounded px-2 py-1 text-xs">
        ${options.map((opt) => `<option value="${this.escape(opt)}" ${opt === value ? "selected" : ""}>${this.escape(opt)}</option>`).join("")}
      </select>`

    return `
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
          <label class="text-t2">Kind ${select("kind", this.kindsValue, slot.kind)}</label>
          <label class="text-t2">Orientation ${select("orientation", this.orientationsValue, slot.orientation)}</label>
          <label class="text-t2">Finish ${select("finish", this.finishesValue, slot.finish)}</label>
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
      </div>`
  }

  // Inputs shared by text and overlay cards.
  boxInput(type, index, field, value, attrs = "") {
    const inputType = attrs.includes("type=") ? "" : `type="number"`
    return `<input ${inputType} ${attrs} value="${this.escape(value)}" data-type="${type}" data-index="${index}" data-field="${field}"
                   data-action="input->scene-calibrator#editBoxField" class="admin-input border rounded px-2 py-1 w-full" />`
  }

  boxSelect(type, index, field, options, value) {
    return `
      <select data-type="${type}" data-index="${index}" data-field="${field}" data-action="change->scene-calibrator#editBoxField"
              class="admin-input border rounded px-2 py-1 text-xs w-full">
        ${options.map((opt) => `<option value="${this.escape(opt)}" ${opt === value ? "selected" : ""}>${this.escape(opt)}</option>`).join("")}
      </select>`
  }

  boxInputs(type, item, index) {
    return `
      <div class="grid grid-cols-4 gap-1 text-[11px] text-t3 mb-1">
        ${["x", "y", "w", "h"].map((name, axis) => `
          <label>${name}
            <input type="number" value="${item.box[axis]}" data-type="${type}" data-index="${index}" data-field="box"
                   data-axis="${axis}" data-action="input->scene-calibrator#editBoxField"
                   class="admin-input border rounded px-1 py-0.5 w-full" />
          </label>`).join("")}
      </div>`
  }

  cardHeader(type, index, title) {
    return `
      <div class="flex items-center justify-between mb-2">
        <span class="text-xs font-medium text-t1">${title}</span>
        <button type="button" class="text-[11px] text-red-500 hover:underline"
                data-type="${type}" data-index="${index}" data-action="click->scene-calibrator#removeBox">Remove</button>
      </div>`
  }

  textCard(slot, index) {
    const font = this.fontsValue[slot.font] || { min: 100, max: 900 }
    const selected = this.isSelectedBox("text", index)

    return `
      <div class="admin-card border rounded-lg p-3 mb-3 ${selected ? "ring-2 ring-pink-500" : ""}"
           data-type="text" data-index="${index}" data-action="click->scene-calibrator#selectBox">
        ${this.cardHeader("text", index, `Text ${index + 1}`)}
        <div class="grid grid-cols-2 gap-2 text-xs mb-2">
          <label class="text-t2">Key ${this.boxInput("text", index, "key", slot.key, `type="text"`)}</label>
          <label class="text-t2">Label ${this.boxInput("text", index, "label", slot.label, `type="text"`)}</label>
          <label class="text-t2">Font ${this.boxSelect("text", index, "font", Object.keys(this.fontsValue), slot.font)}</label>
          <label class="text-t2">Weight ${this.boxInput("text", index, "weight", slot.weight, `step="100" min="${font.min}" max="${font.max}"`)}</label>
          <label class="text-t2">Colour ${this.boxInput("text", index, "color", slot.color, `type="color"`)}</label>
          <label class="text-t2">Align ${this.boxSelect("text", index, "align", this.alignsValue, slot.align)}</label>
          <label class="text-t2">Max px ${this.boxInput("text", index, "max_px", slot.max_px, `min="6" max="400"`)}</label>
          <label class="text-t2">Min px ${this.boxInput("text", index, "min_px", slot.min_px, `min="6" max="400"`)}</label>
          <label class="text-t2">Max chars ${this.boxInput("text", index, "max_chars", slot.max_chars, `min="1" max="${this.maxCharsValue}"`)}</label>
          <label class="text-t2">Rotation° ${this.boxInput("text", index, "rotation", slot.rotation, `step="0.5" min="-180" max="180"`)}</label>
          <label class="text-t2 col-span-2">Default words (blank draws nothing)
            ${this.boxInput("text", index, "default", slot.default, `type="text" maxlength="${this.maxCharsValue}"`)}
          </label>
        </div>
        ${this.boxInputs("text", slot, index)}
        <p class="text-[11px] text-t3" data-box-readout="text-${index}"></p>
      </div>`
  }

  overlayCard(region, index) {
    const selected = this.isSelectedBox("overlay", index)

    return `
      <div class="admin-card border rounded-lg p-3 mb-3 ${selected ? "ring-2 ring-pink-500" : ""}"
           data-type="overlay" data-index="${index}" data-action="click->scene-calibrator#selectBox">
        ${this.cardHeader("overlay", index, `Overlay ${index + 1}`)}
        <div class="grid grid-cols-2 gap-2 text-xs mb-2">
          <label class="text-t2">Key ${this.boxInput("overlay", index, "key", region.key, `type="text"`)}</label>
          <label class="text-t2">Partial ${this.boxSelect("overlay", index, "partial", this.partialsValue, region.partial)}</label>
        </div>
        ${this.boxInputs("overlay", region, index)}
        <p class="text-[11px] text-t3" data-box-readout="overlay-${index}"></p>
      </div>`
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

    ;[["text", this.textSlots], ["overlay", this.overlays]].forEach(([type, list]) => {
      list.forEach((item, index) => {
        const readout = this.listTarget.querySelector(`[data-box-readout="${type}-${index}"]`)
        if (readout) readout.innerHTML = this.boxReadout(type, item)

        this.listTarget.querySelectorAll(`input[data-field="box"][data-type="${type}"][data-index="${index}"]`).forEach((input) => {
          if (input === document.activeElement) return
          input.value = item.box[Number(input.dataset.axis)]
        })
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
    if (this.duplicateKey(slot.key)) problems.push(`key "${slot.key}" is used twice`)

    return `${width}×${height} · aspect ${aspect.toFixed(2)} (${shape})` +
      (problems.length ? ` · <span class="text-red-500">${this.escape(problems.join("; "))}</span>` : "")
  }

  // The same checks the model makes, as warnings. The model is still the gate.
  boxReadout(type, item) {
    const [x, y, w, h] = item.box
    const problems = []
    if (!(w > 0 && h > 0)) problems.push("width and height must be positive")
    if (x < 0 || y < 0 || x + w > this.widthValue || y + h > this.heightValue) problems.push("box must be inside the image")
    if (!/^[a-z0-9_-]{1,40}$/.test(item.key)) problems.push("key must be lowercase letters, digits, - or _")
    if (this.duplicateKey(item.key)) problems.push(`key "${item.key}" is used twice`)

    if (type === "text") {
      const font = this.fontsValue[item.font]
      if (font && (item.weight < font.min || item.weight > font.max || item.weight % 100 !== 0)) {
        problems.push(`weight for ${item.font} must be ${font.min}–${font.max} in hundreds`)
      }
      if (item.min_px > item.max_px) problems.push("min px is larger than max px")
      if (item.default.length > item.max_chars) problems.push("default words are longer than max chars")
      if (!/^#[0-9a-fA-F]{6}$/.test(item.color)) problems.push("colour must be a hex like #17385c")
    }

    return `${w}×${h} at ${x},${y}` +
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

  // Defaults match SceneTemplate.normalize_text_slot.
  normalizeText(slot) {
    const font = this.fontsValue[slot.font] ? slot.font : "nunito"
    return {
      key: slot.key || "",
      label: slot.label || "",
      box: (slot.box || [0, 0, 100, 40]).map((n) => Number(n)),
      rotation: Number(slot.rotation) || 0,
      font,
      weight: Number(slot.weight) || this.fontsValue[font]?.default_weight || 700,
      color: slot.color || "#17385c",
      align: slot.align || "center",
      max_px: Number(slot.max_px) || 48,
      min_px: Number(slot.min_px) || 16,
      max_chars: Number(slot.max_chars) || 60,
      default: slot.default || "",
    }
  }

  normalizeOverlay(region) {
    return {
      key: region.key || "",
      box: (region.box || [0, 0, 100, 100]).map((n) => Number(n)),
      partial: region.partial || this.partialsValue[0],
    }
  }

  boxList(type) {
    return type === "text" ? this.textSlots : this.overlays
  }

  isSelectedBox(type, index) {
    return !!this.boxSelection && this.boxSelection.type === type && this.boxSelection.index === index
  }

  selectBoxAt(type, index) {
    if (!this.boxList(type)[index]) return
    this.boxSelection = { type, index }
    this.active = -1
    this.renderList()
    this.renderStage()
  }

  // Slot, text and overlay keys share one namespace (the model enforces it).
  allKeys() {
    return [...this.slots, ...this.textSlots, ...this.overlays].map((item) => item.key)
  }

  duplicateKey(key) {
    return this.allKeys().filter((k) => k === key).length > 1
  }

  uniqueKey(prefix) {
    const keys = this.allKeys()
    let n = 1
    while (keys.includes(`${prefix}${n}`)) n += 1
    return `${prefix}${n}`
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
