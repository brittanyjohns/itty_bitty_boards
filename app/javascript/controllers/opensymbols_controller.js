import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="opensymbols"
export default class extends Controller {
  connect() {
    console.log("Hello, opensymbols!", this.element)

  }

  queryForSymbols() {
    console.log("queryForSymbols")
    const query = this.element.querySelector("input").value
    console.log("query", query)
  }
}
