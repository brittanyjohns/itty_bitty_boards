import { Controller } from "@hotwired/stimulus"
const { userAgent } = window.navigator
export const isIos = userAgent.includes("iPhone") || userAgent.includes("iPad")
export const isAndroid = userAgent.includes("Android")
// Connects to data-controller="speak"
export default class extends Controller {
  static targets = ["audio"]
  connect() {
    if (isIos || isAndroid) {
      console.log("This is a mobile device")
      this.addTouchStart();
    } else {
      console.log("This is not a mobile device")
      this.addOnClick();
    }
    this.label = this.data.get("label");
    this.thelistOutlet = document.querySelector("#the-list");
    this.isAMenu = document.querySelector("#menu-info");
    this.audio = this.audioTarget.src;

  }

  addTouchStart() {
    const self = this;
    this.element.addEventListener('touchstart', function() {
      if (self.audio) {
        self.playAudio();
      } else {
        self.speak();
      }
      console.log("touchstart");
    });
  }

  addOnClick() {
    const self = this;
    this.element.addEventListener('click', function() {
      if (self.audio) {
        self.playAudio();
      } else {
        self.speak();
      }
    }
    );
  }

  playAudio(event) {
    event.preventDefault();
    console.log("Playing audio", this.audio);
    
    const audio = new Audio(this.audio);
    audio.play();
  }

  speak(event) {
    if (event) {
      event.preventDefault();
    }
    if (this.label === null) {
      return;
    }
    const utterance = new SpeechSynthesisUtterance(this.label);

    utterance.pitch = 1.5;
    utterance.volume = 0.7;
    utterance.rate = 1.3;
    speechSynthesis.speak(utterance);
    this.addToList(this.label);
  }
  addToList(word) {
    // this.thelistOutlet.innerHTML += `<li class="ml-1 lg:block tex-xs md:text-md">${word}</li>`;
    this.thelistOutlet.value += ` ${word}`;
  }

  removeFromList() {
    // const listItems = this.thelistOutlet.querySelectorAll("li");
    const listItems = this.thelistOutlet.value.split(" ");
    listItems.forEach((item) => {
      if (item.innerText === this.label) {
        item.remove();
      }
    });
  }

  clear() {
    this.thelistOutlet.value = "";
  }

  speakList() {
    console.log("Speaking list")
    const listItems = this.thelistOutlet.value.split(" ");
    console.log(listItems);
    let items = [];
    if (this.isAMenu) {
      items.push("I would like to order:");
    }
    listItems.forEach((item) => {
      if(item !== "") {
        items.push(item);
      }
    });
    const utterance = new SpeechSynthesisUtterance(items);
    utterance.pitch = 1.5;
    utterance.volume = 0.7;
    utterance.rate = 1.3;
    speechSynthesis.speak(utterance);
  }

  keyPress(event) {
    if (event.key === "Enter") {
      this.speakList();
    } else if (event.key === "Escape") {
      this.clear();
    }
  }
}
