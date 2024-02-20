import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="show"
export default class extends Controller {
  static targets = [ "target"]
  connect() {
    console.log("Hello from show_controller.js");
  }
  toggle(event) {
    event.preventDefault();
    this.targetTarget.classList.toggle("hidden");
  }
}
