import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="enlarge"
export default class extends Controller {
  static targets = ["image"]
  connect() {
    this.imageTarget.style.width = "100px";
    console.log("connected");
    console.log(this.imageTarget);
  }
}
