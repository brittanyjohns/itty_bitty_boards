import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="wait"
export default class extends Controller {
  static targets = [ "spinner", "indicator"]
  connect() {
    console.log("Hello, Wait Controller!", this.element)
    // const spinner = this.spinnerTarget
    // console.log(spinner)
    // spinner.classList.remove("hidden")
    const buttons = document.querySelectorAll("button")
    buttons.forEach((button) => {
      console.log("button", button)
    })
    // const button = this.buttonTarget
    // console.log(button)
  }

  trigger() {
    console.log("trigger")
    const spinner = this.spinnerTarget
    console.log(spinner)
    spinner.classList.remove("hidden")
    const indicator = this.indicatorTarget
    indicator.classList.add("hidden")
    const buttons = document.querySelectorAll("button")
    buttons.forEach((button) => {
      console.log("button", button)
      button.disabled = true
    })
  }
}
