import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="teams"
export default class extends Controller {
  connect() {
    console.log("Hello, Stimulus TEAMS!", this.element)
  }

  setCurrent(event) {
    event.preventDefault()
    const teamId = event.target.dataset.id
    console.log("Setting current team to", teamId)
    console.log("this.element", this.element)
    this.timeout = setTimeout(() => {
      this.element.requestSubmit();
    }, 400);
  }
}
