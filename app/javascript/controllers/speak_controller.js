import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="speak"
export default class extends Controller {
  connect() {
    this.label = this.data.get("label");
    console.log("CONNECTED: " + this.label);
  }
  speak(event) {
    event.preventDefault();
    console.log("SPEAKING: " + this.label);
    const utterance = new SpeechSynthesisUtterance(this.label);

    utterance.pitch = 1.5;
    utterance.volume = 0.7;
    utterance.rate = 1;
    speechSynthesis.speak(utterance);
  }
}
