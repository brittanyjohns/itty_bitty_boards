import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="generate-image"
export default class extends Controller {
  static targets = ["image_prompt"]
  connect() {
    console.log("Hello, GenerateImageController!", this.element);
    this.image_id = this.element.dataset.imageId;
  }

  generate(event) {
    event.preventDefault();
    console.log("Generate image");
    this.imagePrompt = this.image_promptTarget.value;
    this.submit();
  }

  submit() {
    fetch(`/images/${this.image_id}/generate`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')
          .content,
      },
      body: JSON.stringify({
        image_prompt: this.imagePrompt,
      }),
    })
      .then((response) => response.json())
      .then((data) => {
        console.log(`data:${data}`); // Look at local_names.default
        if (data.status === "success") {
          console.log("Success");
          if (data.redirect_url) {
            this.waitNotice = document.querySelector("#pleaseWait");
            this.waitNotice.classList.remove("hidden");
            setTimeout(() => window.location.reload(), 30000)
            // window.location.href = data.redirect_url;
            // window.location.reload();
          } else {
            console.log("No redirect url");
          }
        }
      })
      .catch((error) => {
        console.error("Error:", error);
      });
  }
}
