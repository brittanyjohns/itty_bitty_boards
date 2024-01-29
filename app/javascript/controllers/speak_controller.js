import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="speak"
export default class extends Controller {
  connect() {
    this.label = this.data.get("label");
    this.thelistOutlet = document.querySelector("#the-list");
    this.isAMenu = document.querySelector("#menu-info");
  }

  speak(event) {
    event.preventDefault();
    const utterance = new SpeechSynthesisUtterance(this.label);

    utterance.pitch = 1.5;
    utterance.volume = 0.7;
    utterance.rate = 1.3;
    speechSynthesis.speak(utterance);
    this.addToList(this.label);
  }
  addToList(word) {
    this.thelistOutlet.innerHTML += `<li class="ml-1 lg:block">${word}</li>`;
  }

  removeFromList() {
    const listItems = this.thelistOutlet.querySelectorAll("li");
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
    console.log("SPEAKING LIST");
    const listItems = this.thelistOutlet.querySelectorAll("li");
    console.log(listItems);
    let items = [];
    if (this.isAMenu) {
      items.push("I would like to order:");
    }
    listItems.forEach((item) => {
      items.push(item.innerText);
    });
    const utterance = new SpeechSynthesisUtterance(items);
    utterance.pitch = 1.5;
    utterance.volume = 0.7;
    utterance.rate = 1.3;
    speechSynthesis.speak(utterance);
  }
}
