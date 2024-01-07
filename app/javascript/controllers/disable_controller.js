import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="disable"
export default class extends Controller {
  // static values = { with: String };
  static targets = ["button"];

  connect() {
    console.log("Connected to disable controller");
    console.log(`buttonTarget: ${this.buttonTarget.value}`);

    if (!this.hasWithValue) {
      this.withValue = "Processing...";
    }
  }

  disableForm = (e) => {
    console.log("disableForm");
    console.log(e);
    const button = this.buttonTarget || e.srcElement;
    console.log(`button: ${button.value}`);

    button.disabled = true;
    button.textContent = this.withValue;
    this.element.requestSubmit();
  };
}
