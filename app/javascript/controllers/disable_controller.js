import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="disable"
export default class extends Controller {
  // static values = { with: String };

  connect() {
    console.log("Connected to disable controller");
    console.log(this.element);

    if (!this.hasWithValue) {
      this.withValue = "Processing...";
    }
  }

  disableForm = (e) => {
    // const button = this.buttonTarget || e.srcElement;
    // console.log(`disableForm - button: ${button.value}`);
    const buttons = document.querySelectorAll("button")
    buttons.forEach((button) => {
      console.log("button", button)
      button.disabled = true
      button.textContent = this.withValue;
    })    
    this.element.requestSubmit();
  };
}
