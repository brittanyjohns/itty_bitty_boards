import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="speak"
export default class extends Controller {
  connect() {
    this.label = this.data.get("label");
    this.thelistOutlet = document.querySelector("#the-list");
  }
  speak(event) {
    event.preventDefault();
    const utterance = new SpeechSynthesisUtterance(this.label);

    utterance.pitch = 1.5;
    utterance.volume = 0.7;
    utterance.rate = 1;
    speechSynthesis.speak(utterance);
    this.addToList(this.label);
  }
  addToList(word) {
    this.thelistOutlet.innerHTML += `<div class="p-2 inline">${word}</div>`;
  }

  removeFromList() {
    const listItems = this.thelistOutlet.querySelectorAll("div");
    listItems.forEach((item) => {
      if (item.innerText === this.label) {
        item.remove();
      }
    });
  }

  clear() {
    console.log("CLEARING LIST");
    this.thelistOutlet.innerHTML = "";
  }

  speakList() {
    const listItems = this.thelistOutlet.querySelectorAll("div");
    listItems.forEach((item) => {
      const utterance = new SpeechSynthesisUtterance(item.innerText);
      utterance.pitch = 1.5;
      utterance.volume = 0.7;
      utterance.rate = 1;
      speechSynthesis.speak(utterance);
    });
  }
}
