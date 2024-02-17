import { Controller } from "@hotwired/stimulus"
const { userAgent } = window.navigator
export const isIos = userAgent.includes("iPhone") || userAgent.includes("iPad")
export const isAndroid = userAgent.includes("Android")
// Connects to data-controller="navbar"
export default class extends Controller {
  static targets = [ "menu" ]
  connect() {
    console.log("Hello, Navbar!", this.element)
    window.addEventListener("toggle-nav-bar", this.toggle)

    // if (isIos) {
    //   console.log("This is an iOS device")
    //   this.hide()
    // }
    // if (isAndroid) {
    //   console.log("This is an Android device")
    //   this.hide()
    // }

  }
  hide() {
    this.element.classList.add("hidden")
  }
  toggle(event) {
    console.log("toggle")
    this.menuTarget.classList.toggle("hidden")
  }
}
