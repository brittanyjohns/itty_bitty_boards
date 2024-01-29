import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="grid"
export default class extends Controller {
  static targets = [ "number_of_columns", "grid" ]
  connect() {
    console.log("Grid controller connected", this.number_of_columnsTarget.value)
    this.gridTarget.style.gridTemplateColumns = `repeat(${this.number_of_columnsTarget.value}, 1fr)`
  }

  changeGrid() {
    console.log("Grid controller connected", this.number_of_columnsTarget.value)
    this.gridTarget.style.gridTemplateColumns = `repeat(${this.number_of_columnsTarget.value}, 1fr)`
    // this.gridTarget.style.gridTemplateRows = `repeat(${this.number_of_columnsTarget.value}, 1fr)`
    this.updateBoard()
  }

  updateBoard() {
    const currentUrl = window.location.href;
    const boardId = currentUrl.split("/")[4];
    console.log("boardId", boardId)
    fetch(`/boards/${boardId}/update_grid`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': document.querySelector("meta[name=csrf-token]").content
      },
      body: JSON.stringify({number_of_columns: this.number_of_columnsTarget.value})
    })
      .then(response => response.json())
      .then(data => {
        console.log("data", data)
      })
      .catch(error => {
        console.error("Error:", error);
      });
  }
}
