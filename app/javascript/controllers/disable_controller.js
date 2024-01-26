import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="disable"
export default class extends Controller {
  static targets = ["button"];

  connect() {
    console.log("Connected to disable controller");
    console.log(this.element);
    this.fileInput = this.element.querySelector("input[type=file]");
    console.log("fileInput", this.fileInput);
    this.fileInput.addEventListener("change", this.enableSubmitForm);
  }

  enableSubmitForm = (e) => {
    e.preventDefault();
    console.log("enableSubmitForm");
    this.buttonTarget.disabled = false;
  };
}
