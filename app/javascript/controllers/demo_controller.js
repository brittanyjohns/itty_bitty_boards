import { Controller } from "@hotwired/stimulus"
import introJs from "intro.js"

// Connects to data-controller="demo"
export default class extends Controller {
  connect() {
    console.log("Hello from demo_controller.js")
    this.shouldPlay = this.element.dataset.play === "true"
    console.log("Intro.js started", this.shouldPlay)
    if (this.shouldPlay) {
      introJs().setOption("dontShowAgain", true).start();
      introJs().addHints();
    }
  }
  

  clearCookie() {
    console.log("Clearing cookie")
    const cookieName = "introjs-dontShowAgain"
    document.cookie = `${cookieName}=; expires=Thu, 01 Jan 1970 00:00:00 UTC; path=/;`
    console.log("Cookie cleared")
    window.location.reload()
    }
}
