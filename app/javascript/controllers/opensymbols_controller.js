import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="opensymbols"
export default class extends Controller {
  connect() {
    this.getAccessSecret()
    this.isLoading = document.querySelector(".loading_spinner")
    this.waitNotice = document.querySelector("#pleaseWait");
    if (this.isLoading != null) {
      this.notifyAndReload
    }

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
      console.log("Done.")
    })
  }

  notifyAndReload() {
    this.waitNotice.classList.remove("hidden");
    setTimeout(() => window.location.reload(), 4000)
    
  }
}
