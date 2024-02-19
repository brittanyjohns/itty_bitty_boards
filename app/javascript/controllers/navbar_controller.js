import { Controller } from "@hotwired/stimulus"
const { userAgent } = window.navigator
export const isIos = userAgent.includes("iPhone") || userAgent.includes("iPad")
export const isAndroid = userAgent.includes("Android")
export const isTurboNativeApp = () => userAgent.includes("Turbo Native")
// Connects to data-controller="navbar"
export default class extends Controller {
  static targets = [ "menu" ]
  connect() {
    console.log("Hello, Navbar!", this.element)
    window.addEventListener("toggle-nav-bar", this.toggleMobileMenu)

    if (isTurboNativeApp()) {
      console.log("This is a Turbo Native app")
      this.hide()
    }
    // if (isAndroid) {
    //   console.log("This is an Android device")
    //   this.hide()
    // }

  }

  toggleMobileMenu(event) {
    console.log("toggleMobileMenu **", event)
    const mobileMenu = document.querySelector("#mobile-nav")
    console.log("mobileMenu", mobileMenu)
    mobileMenu.classList.toggle("hidden")
  }

  toggleMainNav(event) {
    this.mainNavBar = document.querySelector("#main-navbar")
    console.log("toggleMainNav **", JSON.stringify(this.mainNavBar))
    console.log("event", event)
    this.mainNavBar.classList.toggle("hidden")
  }
  hide() {
    this.element.classList.add("hidden")
  }
  toggle(event) {
    console.log("event", event)
    console.log("toggle **")
    if (this.menuTarget) {
      this.menuTarget.classList.toggle("hidden")
    }
    console.log("element", this.element)
  }
}
