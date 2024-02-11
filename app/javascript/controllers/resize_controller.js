import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["grid"]

  connect() {
    this.resizeGrid();
    window.addEventListener('resize', () => this.resizeGrid());
  }

  resizeGrid() {
    const imagesCount = this.gridTarget.children.length;
    const sqrt = Math.sqrt(imagesCount);
    const rows = Math.ceil(sqrt);
    const cols = Math.round(sqrt);

    // Subtract the input box height (50px) and the margin (assumed 1rem or 16px on each side, total 32px) from the viewport height
    const adjustedHeight = `calc(100vh - 50px - 32px)`;
    const adjustedWidth = `calc(100vw - 32px)`;

    this.gridTarget.style.height = adjustedHeight;
    this.gridTarget.style.width = adjustedWidth;

    // Dynamically set the grid template columns and rows
    this.gridTarget.style.gridTemplateColumns = `repeat(${cols}, minmax(0, 1fr))`;
    this.gridTarget.style.gridTemplateRows = `repeat(${rows}, minmax(0, 1fr))`;
  }
}
