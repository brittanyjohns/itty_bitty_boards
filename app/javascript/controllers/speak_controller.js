import { Controller } from "@hotwired/stimulus";
import { list } from "postcss";
const { userAgent } = window.navigator;
export const isIos = userAgent.includes("iPhone") || userAgent.includes("iPad");
export const isAndroid = userAgent.includes("Android");
// Connects to data-controller="speak"
export default class extends Controller {
  static targets = ["speaker", "audio"];
  connect() {
    this.label = this.data.get("label");
    this.thelistOutlet = document.querySelector("#the-list");
    // this.playlist = document.querySelector("#the-playlist");
    this.isAMenu = document.querySelector("#menu-info");
    const parameterizedLabel = this.label.toLowerCase().replace(/ /g, "-");
    const idToFind = `audio-${parameterizedLabel}`;
    // this.audioTarget = this.element.querySelector(`#${idToFind}`);
    if (this.hasSpeakerTarget) {
      this.soundTarget = this.speakerTarget;
    } else {
      this.soundTarget = this.element;
    }
    if (this.hasAudioTarget) {
      if (this.audioTarget !== null) {
        this.audio = this.audioTarget.src;
      }
    } else {
      this.audio = null;
    }
    // if (isIos || isAndroid) {
    //   this.addTouchStart();
    // } else {
    //   this.addOnClick();
    // }
  }

  // addTouchStart() {
  //   const self = this;
  //   this.soundTarget.addEventListener("touchstart", function () {
  //     if (self.audio) {
  //       self.playAudio();
  //     } else {
  //       self.speak();
  //     }
  //   });
  // }

  // addOnClick() {
  //   const self = this;
  //   this.soundTarget.addEventListener("click", function () {
  //     if (self.audio) {
  //       self.playAudio();
  //     } else {
  //       self.speak();
  //     }
  //   });
  // }

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
    console.log("Speaking", this.label);
    utterance.pitch = 1.5;
    utterance.volume = 0.7;
    utterance.rate = 1.3;
    speechSynthesis.speak(utterance);
    this.addToList(this.label);
  }

  addToList(word) {
    if (this.thelistOutlet.value === undefined) {
      this.thelistOutlet.innerHTML += ` <li class='pl-1'> ${word}</li>`;
    } else {
      this.thelistOutlet.value += ` ${word}`;
    }
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
    if (this.thelistOutlet.value === undefined) {
      this.thelistOutlet.innerHTML = "";
    } else {
      this.thelistOutlet.value = "";
    }
  }

  playListAudio() {
    // const playListItems = this.playlist.querySelectorAll("li");
    const listItems = this.thelistOutlet.value.split(" ");
    console.log("Playing playlist audio");
    listItems.forEach((label) => {
      const strLabel = label;
      const parameterizedLabel = strLabel.toLowerCase().replace(/ /g, "-");
      const idToFind = `audio-${parameterizedLabel}`;
      const foundAudioTarget = this.element.querySelector(`#${idToFind}`);
      console.log("Looking for audio for", label);
      if (foundAudioTarget === null) {
        console.log("No audio found for", label);
        const utterance = new SpeechSynthesisUtterance(label);

        utterance.pitch = 1.5;
        utterance.volume = 0.7;
        utterance.rate = 1.3;
        speechSynthesis.speak(utterance);
      } else {
        console.log("Playing audio for", label);
        const audioFile = new Audio(foundAudioTarget.src);

        console.log("Playing audio", audioFile);
        audioFile.play();

        let count = 1;
        let timer = setInterval(function () {
          // Reduce count by 1
          count--;

          // Update the UI
          if (count > 0) {
            console.log("Waiting to play audio");
          } else {
            clearInterval(timer);
            audioFile.play();
          }
        }, 500);
      }
    });
  }

  speakList() {
    console.log("Speaking list");
    let listItems = [];
    if (this.thelistOutlet.value === undefined) {
      const listElements = this.thelistOutlet.querySelectorAll("li");
      listElements.forEach((item) => {
        listItems.push(item.innerText);
      });
    } else {
      listItems = this.thelistOutlet.value.split(" ");
    }
    console.log(listItems);
    let items = [];
    if (this.isAMenu) {
      items.push("I would like to order:");
    }
    listItems.forEach((item) => {
      if (item !== "") {
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
