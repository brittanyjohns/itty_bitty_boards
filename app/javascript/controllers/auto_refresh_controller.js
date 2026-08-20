import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="auto-refresh"
//
// Reloads the page on an interval while something finishes server-side (a
// board printable generating, say). This replaces a
// `<meta http-equiv="refresh">`: Turbo Drive merges <head> across visits and
// leaves a stale refresh meta behind, so the timer followed you off the page
// and reloaded whatever you navigated to next. A controller's timer is tied to
// the element, and disconnect() runs on every Turbo navigation and before the
// page is cached — so leaving the page stops the refresh, which is the whole
// point.
export default class extends Controller {
  static values = { interval: { type: Number, default: 5000 } }

  connect() {
    this.timer = setTimeout(() => window.location.reload(), this.intervalValue)
  }

  disconnect() {
    clearTimeout(this.timer)
    this.timer = null
  }
}
