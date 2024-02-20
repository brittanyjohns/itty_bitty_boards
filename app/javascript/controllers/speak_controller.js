import { Controller } from "@hotwired/stimulus"
import { list } from "postcss";
const { userAgent } = window.navigator
export const isIos = userAgent.includes("iPhone") || userAgent.includes("iPad")
export const isAndroid = userAgent.includes("Android")
// Connects to data-controller="speak"
export default class extends Controller {
  // static targets = ["audio"]
  connect() {
    this.label = this.data.get("label");
    this.thelistOutlet = document.querySelector("#the-list");
    console.log("The list outlet is", this.thelistOutlet);
    // this.playlist = document.querySelector("#the-playlist");
    console.log("Hello, Stimulus! Speak", this.playlist, this.label);
    this.isAMenu = document.querySelector("#menu-info");
    const parameterizedLabel = this.label.toLowerCase().replace(/ /g, "-");
    const idToFind = `audio-${parameterizedLabel}`;
    this.audioTarget = this.element.querySelector(`#${idToFind}`);
    if (this.audioTarget !== null) {
      this.audio = this.audioTarget.src;
    }
    if (isIos || isAndroid) {
      console.log("This is a mobile device")
      this.addTouchStart();
    } else {
      console.log("This is not a mobile device")
      this.addOnClick();
    }
  }

  addTouchStart() {
    const self = this;
    this.element.addEventListener('touchstart', function() {
      if (self.audio) {
        self.playAudio();
      } else {
        self.speak();
      }
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
    if (event) {
      event.preventDefault();
    }    
    const audio = new Audio(this.audio);
    audio.play();
    this.addToList(this.label);
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
    this.thelistOutlet.value += ` ${word}`;
  }
// WIP
  // addToPlaylist(labelToAdd) {
  //   console.log("adding to playlist", labelToAdd);
  //   // this.playlist.push(this.audio);
  //   this.playlist.innerHTML += ` <li>${labelToAdd}</li>`;
  //   console.log(this.playlist);
  // }


  removeFromList() {
    // const listItems = this.thelistOutlet.querySelectorAll("li");
    let listItems = [];
    if (this.thelistOutlet.value === undefined) {
      listItems = this.thelistOutlet.querySelectorAll("li");
    }
    listItems = this.thelistOutlet.value.split(" ");
    listItems.forEach((item) => {
      if (item.innerText === this.label) {
        item.remove();
      }
    });
  }

  clear() {
    this.thelistOutlet.value = "";
  }

// WIP  playListAudio() {
  //       // const playListItems = this.playlist.querySelectorAll("li");
  //       const listItems = this.thelistOutlet.value.split(" ");
  //   console.log("Playing playlist audio");
  //   listItems.forEach((label) => {
  //     const strLabel = label;
  //     const parameterizedLabel = strLabel.toLowerCase().replace(/ /g, "-");
  //     const idToFind = `audio-${parameterizedLabel}`;
  //     const audioTarget = this.element.querySelector(`#${idToFind}`);
  //     if (audioTarget === null) {
  //       const utterance = new SpeechSynthesisUtterance(label);

  //       utterance.pitch = 1.5;
  //       utterance.volume = 0.7;
  //       utterance.rate = 1.3;
  //       speechSynthesis.speak(utterance);
  //     } else {
  //     const audio = audioTarget.src;
  //     console.log("Playing audio for", audio)

  //     const audioFile = new Audio(audio);
  //     let count = 2;
  //     let timer = setInterval(function () {

  //       // Reduce count by 1
  //       count--;
      
  //       // Update the UI
  //       if (count > 0) {
  //         console.log("Waiting to play audio");
  //       } else {
  //         clearInterval(timer);
  //         audioFile.play();
  //       }
      
  //     }, 500);
  //     }
  //   });
  // }


  speakList() {
    console.log("Speaking list")
    let listItems = [];
    if (this.thelistOutlet.value === undefined) {
      const listElements = this.thelistOutlet.querySelectorAll("li");
      listElements.forEach((item) => {
        listItems.push(item.innerText);
      }
      );
    } else {
      listItems = this.thelistOutlet.value.split(" ");
    }
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
