import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="pwa"
export default class extends Controller {
  static targets = ["button"]
  connect() {
    if (window.matchMedia('(display-mode: standalone)').matches) {
      console.log('display-mode is standalone');
      this.buttonTarget.style.display = "none";
    }
  }

  fullscreen() {
    let elem = document.documentElement; // Get the documentElement (<html>) to display the page in fullscreen
    this.isFullscreen = document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement || document.msFullscreenElement;

    if (this.isFullscreen) {
      this.buttonTarget.innerHTML = '<i class="fas fa-expand"></i>';
      if (document.exitFullscreen) {
        document.exitFullscreen();
      } else if (document.webkitExitFullscreen) { /* Safari */
        document.webkitExitFullscreen();
      } else if (document.msExitFullscreen) { /* IE11 */
        document.msExitFullscreen();
      }      
    } else {
      this.buttonTarget.innerHTML = '<i class="fas fa-compress"></i>';
      if (elem.requestFullscreen) {
        elem.requestFullscreen();
      } else if (elem.webkitRequestFullscreen) { /* Safari */
        elem.webkitRequestFullscreen();
      } else if (elem.msRequestFullscreen) { /* IE11 */
        elem.msRequestFullscreen();
      }
    }
  }
}
