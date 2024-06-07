import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="voices"
export default class extends Controller {
  connect() {
    console.log("Hello, Stimulus! Voices", this.element)
    const voice = "echo"
    const idToFind = `this-is-the-voice-${voice}`
    const audioPlayer = this.element.querySelector(`#${idToFind}`);
    audioPlayer.classList.remove("hidden");
  }

  changeVoice(event) {
    event.preventDefault();
    const voice = event.target.value;
    const idToFind = `this-is-the-voice-${voice}`
    const audioPlayer = this.element.querySelector(`#${idToFind}`);
    const otheraudioPlayers = this.element.querySelectorAll(".audio-player");
    otheraudioPlayers.forEach(player => {
      player.classList.add("hidden");
    });
    audioPlayer.classList.remove("hidden");
  }
}
