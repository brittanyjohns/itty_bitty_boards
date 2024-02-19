import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="voices"
export default class extends Controller {
  connect() {
    console.log("Hello, Stimulus! Voices", this.element)
    // this.voiceField = this.element.querySelector("#board_voice");
    // this.voiceField.addEventListener("change", this.showAudioPlayer.bind(this));
    // const testing = document.querySelector("#this-is-the-voice-onyx");
    
  }

  changeVoice(event) {
    console.log("Show audio player", event);
    event.preventDefault();
    console.log("Change", event.target.value);
    const voice = event.target.value;
    const idToFind = `this-is-the-voice-${voice}`
    console.log("ID to find", idToFind);
    const audioPlayer = this.element.querySelector(`#${idToFind}`);
    const otheraudioPlayers = this.element.querySelectorAll(".audio-player");
    otheraudioPlayers.forEach(player => {
      player.classList.add("hidden");
    });
    console.log("Audio player", audioPlayer);
    audioPlayer.classList.remove("hidden");
    // const audioForVoice = this.voices.find(voice => voice.id == idToFind).audio;
    // console.log("Audio for voice", audioForVoice);
    // const audio = new Audio(audioForVoice);
    // audio.play();

  }
}
