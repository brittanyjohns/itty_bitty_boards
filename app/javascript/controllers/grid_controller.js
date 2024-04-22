import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="grid"
export default class extends Controller {
  static targets = ["number_of_columns", "grid"];
  connect() {
    this.isPredifined = this.element.dataset.predefined;
    this.gridTarget.style.gridTemplateColumns = `repeat(${this.number_of_columnsTarget.value}, 1fr)`;
  }

  changeGrid() {
    this.gridTarget.style.gridTemplateColumns = `repeat(${this.number_of_columnsTarget.value}, 1fr)`;
    // if (this.isPredifined == "false") {
    this.updateBoard();
    // }
  }

  updateBoard() {
    const currentUrl = window.location.href;
    const boardId = currentUrl.split("/")[4];
    fetch(`/boards/${boardId}/update_grid`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector("meta[name=csrf-token]").content,
      },
      body: JSON.stringify({
        number_of_columns: this.number_of_columnsTarget.value,
      }),
    })
      .then((response) => response.json())
      .then((data) => {
        console.log("data", data);
      })
      .catch((error) => {
        console.error("Error:", error);
      });
  }
}
