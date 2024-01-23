import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="pwa"
export default class extends Controller {
  static targets = ["button"]
  connect() {
    // let elem = document.documentElement; // Get the documentElement (<html>) to display the page in fullscreen
    // let isFullscreen = document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement || document.msFullscreenElement;
    // if (isFullscreen) {
    //   if (document.exitFullscreen) {
    //     document.exitFullscreen();
    //   } else if (document.webkitExitFullscreen) { /* Safari */
    //     document.webkitExitFullscreen();
    //   } else if (document.msExitFullscreen) { /* IE11 */
    //     document.msExitFullscreen();
    //   }
    // } else {
    //   if (elem.requestFullscreen) {
    //     elem.requestFullscreen();
    //   } else if (elem.webkitRequestFullscreen) { /* Safari */
    //     elem.webkitRequestFullscreen();
    //   } else if (elem.msRequestFullscreen) { /* IE11 */
    //     elem.msRequestFullscreen();
    //   }
    // }
  }

  fullscreen() {
    console.log('fullscreen');
    let elem = document.documentElement; // Get the documentElement (<html>) to display the page in fullscreen
    this.isFullscreen = document.fullscreenElement || document.webkitFullscreenElement || document.mozFullScreenElement || document.msFullscreenElement;

    if (this.isFullscreen) {
      console.log('exit fullscreen');
      this.buttonTarget.innerHTML = '<i class="fas fa-expand"></i> Enter Fullscreen';
      if (document.exitFullscreen) {
        document.exitFullscreen();
      } else if (document.webkitExitFullscreen) { /* Safari */
        document.webkitExitFullscreen();
      } else if (document.msExitFullscreen) { /* IE11 */
        document.msExitFullscreen();
      }      
    } else {
      console.log('enter fullscreen');
      this.buttonTarget.innerHTML = '<i class="fas fa-compress"></i> Exit Fullscreen';
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
