import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="notice"
export default class extends Controller {
  connect() {
    console.log("Hello, Notice!", this.element)
    const notice = document.querySelector("#notice")
    this.theList = document.querySelector("#the-list")
    console.log("this.theList: ", this.theList)

    if (notice) {
      setTimeout(() => {
        notice.classList.add("hidden")
      }, 3000)
    }
  }

  clearList() {
    console.log("Clearing list")
    this.theList.innerHTML = ""
    const highlighted = document.querySelectorAll(".bg-green-200")
    highlighted.forEach((item) => {
      item.classList.remove("bg-green-200")
      item.classList.add("bg-white")
    })
  }
}
