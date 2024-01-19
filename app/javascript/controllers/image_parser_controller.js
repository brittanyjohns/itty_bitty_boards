import { Controller } from "@hotwired/stimulus";
import Tesseract from "tesseract.js";

// Connects to data-controller="image-parser"
export default class extends Controller {
  static targets = ["file", "image_description", "name","sumbit_button", "please_wait"];
  connect() {
    console.log("Hello from image_parser_controller.js");
    const currentUrl = window.location.href;
    console.log(currentUrl);
    if (!currentUrl.includes("edit")) {
      this.sumbit_buttonTarget.classList.add("hidden");
    }
  }

  upload(event) {
    event.preventDefault();

    let file = this.fileTarget.files[0];
    let reader = new FileReader();

    reader.onload = (event) => {
      this.please_waitTarget.classList.remove("hidden");
      Tesseract.recognize(event.target.result, "eng", {
        logger: (m) => console.log(m),
      }).then(({ data: { text } }) => {
        //  set the value of the hidden field to the text
        this.image_descriptionTarget.value = text;
        //  submit the form
        if (this.nameTarget.value) {
          this.sumbit_buttonTarget.classList.remove("hidden");
          this.please_waitTarget.classList.add("hidden");
          // console.log("submitting form");
          // this.element.requestSubmit();
          //   setTimeout(() => {
          //   this.please_waitTarget.classList.add("hidden");
          //   window.location.href = "/menus";
          // }
          // , 2000);
        } else {
          this.sumbit_buttonTarget.classList.remove("hidden");
          alert("Please enter a name for the menu");
        }


      });
    };
    reader.readAsArrayBuffer(file);
  }

  submit(event) {
    event.preventDefault();
    this.please_waitTarget.classList.remove("hidden");
    console.log("submitting form");
    this.element.requestSubmit();
    setTimeout(() => {
      this.please_waitTarget.classList.add("hidden");
      window.location.href = "/menus";
    }
    , 2000);
  }
}