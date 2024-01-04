import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="disable"
export default class extends Controller {
  // static values = { with: String };
  static targets = ["button"];

  connect() {
    console.log("Connected to disable controller");
    console.log(`buttonTarget: ${this.buttonTarget}`);

    if (!this.hasWithValue) {
      this.withValue = "Processing...";
    }
  }

  disableForm = (e) => {
    const button = this.buttonTarget;

    button.disabled = true;
    button.value = this.withValue;
    this.element.requestSubmit();
  };

  submitButtons() {
    console.log("submitButtons");
    return this.element.querySelectorAll("input[type='submit']");
  }
}
