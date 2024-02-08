import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="dropdown"
export default class extends Controller {
  static targets = [ "content" ]
  connect() {
    console.log('connected to dropdown controller')
  }
  toggle() {
    console.log('toggling dropdown', this.contentTarget)
    this.contentTarget.classList.toggle('hidden')
  }
}
