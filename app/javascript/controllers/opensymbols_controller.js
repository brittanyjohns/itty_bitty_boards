import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="opensymbols"
export default class extends Controller {
  connect() {
    console.log("Hello, opensymbols!", this.element)
    this.getAccessSecret()
  }

  getAccessSecret() {
    fetch("/token", {
      method: "GET",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').getAttribute("content")
      }
    })
    .then(response => response.json())
    .then(data => {
      console.log("access secret set")

      console.log(data)
    })
  }
}
