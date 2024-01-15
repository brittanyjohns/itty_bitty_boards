import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="notice"
export default class extends Controller {
  connect() {
    console.log("Hello, Notice!", this.element)
    const notice = document.querySelector("#notice")
    if (notice) {
      setTimeout(() => {
        notice.classList.add("hidden")
      }, 3000)
    }
  }
}
