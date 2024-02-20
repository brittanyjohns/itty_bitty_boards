import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="fullscreen"
export default class extends Controller {
  static targets = ["button"]
  connect() {
    console.log("Hello, Stimulus! Fullscreen", this.element)
    this.disableZoom();
    if (window.matchMedia('(display-mode: standalone)').matches) {
      console.log('display-mode is standalone');
      this.buttonTarget.style.display = "none";
    }
  }

  disableZoom() {
    document.addEventListener('gesturestart', function(event) {
      console.log("Gesturestart");
      event.preventDefault();
    } );

    document.addEventListener('gesturechange', function(event) {
      console.log("Gesturechange");
      event.preventDefault();
    } );

    document.addEventListener('gestureend', function(event) {
      console.log("Gestureend");
      event.preventDefault();
    }
    );

    document.addEventListener('touchmove', function(event) {
      console.log("Touchmove");
      if (event.scale !== 1) { event.preventDefault(); }
    }, { passive: false });

    document.addEventListener('touchend', function(event) {
      console.log("Touchend");
      if (event.scale !== 1) { event.preventDefault(); }
    }, { passive: false });

    document.addEventListener('touchstart', function(event) {
      console.log("Touchstart");
      if (event.scale !== 1) { event.preventDefault(); }
    }, { passive: false });


    console.log("Zoom disabled");
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
