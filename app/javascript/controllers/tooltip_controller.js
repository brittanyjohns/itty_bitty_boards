import { Controller } from "@hotwired/stimulus"
import tippy from "tippy.js"

// Connects to data-controller="tooltip"
export default class extends Controller {
  connect() {
    console.log('connected to tooltip controller')
    tippy('[data-tippy-content]');

  }
  mouse(e) {
    console.log('toggling tooltip', e)
    this.link = e.target
    this.content = this.link.dataset.tooltip
    console.log('toggling tooltip', this.link.getAttribute('data-tooltip'))
    tippy(this.link, {
      content: this.content,
      // placement: 'right',
      allowHTML: true,
      animation: 'scale',
      arrow: true,
      theme: 'light',
    });
  }
}
