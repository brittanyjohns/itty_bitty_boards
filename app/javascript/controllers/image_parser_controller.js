import { Controller } from "@hotwired/stimulus";
import Tesseract from "tesseract.js";

// Connects to data-controller="image-parser"
export default class extends Controller {
  static targets = ["file", "image_description"];
  connect() {
    console.log("Hello from image_parser_controller.js");
  }

  upload(event) {
    event.preventDefault();

    let file = this.fileTarget.files[0];
    let reader = new FileReader();

    reader.onload = (event) => {
      Tesseract.recognize(event.target.result, "eng", {
        logger: (m) => console.log(m),
      }).then(({ data: { text } }) => {
        //  set the value of the hidden field to the text
        this.image_descriptionTarget.value = text;

        //  submit the form
        this.element.requestSubmit();

      });
    };
    reader.readAsArrayBuffer(file);
  }
}