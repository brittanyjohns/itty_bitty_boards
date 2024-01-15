import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="add-images"
export default class extends Controller {
  static targets = [
    "image",
    "parent",
    "count",
    "imageIds",
    "imageIdsToAdd",
    "image1",
  ];
  connect() {
    this.searchOutlet = document.querySelector("#image_ids");

    this.setInitialCheckboxes();
  }

  setInitialCheckboxes() {
    this.initialIdList = [];
    this.uniqueArr = [];

    const currentUrl = window.location.href;

    const url = new URL(currentUrl);
    const params = new URLSearchParams(url.search);

    this.idsFromParam = params.get("image_ids");
    if (this.idsFromParam) {
      this.initialIdList = this.idsFromParam.split(",");
    }
    this.imageTargets.map((x) => {
      if (this.initialIdList.includes(x.value)) {
        x.checked = true;
      } else {
        x.checked = false;
      }
    });
    this.updateImageIds();
  }

  toggleParent() {
    if (this.imageTargets.map((x) => x.checked).includes(false)) {
      this.parentTarget.checked = false;
    } else {
      this.parentTarget.checked = true;
    }
    this.updateImageIds();
  }

  toggleParent1 = (e) => {
    this.parent1Target = e.target;
    console.log("this.parent1Target", this.parent1Target);

    // this.eventCheckbox = e.target.children[2] ? e.target.children[2] : e.target;
    // console.log("this.eventCheckbox", this.eventCheckbox);
    let ck = this.parent1Target.querySelector('input[type="checkbox"]');
    console.log("ck", ck);
    if (!ck) {
      this.parent1Target.parentElement.classList.toggle("bg-green-200");
      ck = this.parent1Target.parentElement.querySelector('input[type="checkbox"]');
    } else {
      this.parent1Target.classList.toggle("bg-green-200");
    }
    console.log("ck", ck);
    this.eventCheckbox = ck;
    if (this.eventCheckbox) {
      this.eventCheckbox.checked = !this.eventCheckbox.checked;
    }
    // this.eventCheckbox.checked = !this.eventCheckbox.checked;
    // e.target.classList.toggle("bg-green-200");
    this.toggleParent();
  };

  toggleChildren() {
    if (this.parentTarget.checked) {
      this.imageTargets.map((x) => (x.checked = true));
    } else {
      this.imageTargets.map((x) => (x.checked = false));
    }
    this.updateImageIds();
  }

  updateImageLabelList() {
    const imageLabels = this.imageTargets
      .filter((x) => x.checked)
      .map((x) => x.dataset.label);
    this.imageIdsToAddTarget.value = imageLabels.join(", ");
  }

  updateImageIds() {
    const idList = this.imageTargets
      .filter((x) => x.checked)
      .map((x) => x.value);
    const totalList = this.initialIdList.concat(idList);
    this.uniqueArr = [...new Set(totalList)];
    // this.imageIdsToAddTarget.value = this.uniqueArr;
    this.imageIdsTarget.value = this.uniqueArr.join(",");
    this.imageIdsTarget.innerHTML = this.uniqueArr.join(", ");
    this.searchOutlet.value = this.uniqueArr.join(",");

    this.updateCount();
    this.updateCheckboxesWithImageIds();
    this.updateImageLabelList();
  }

  updateCheckboxesWithImageIds() {
    const imageIds = this.imageIdsTarget.value.split(",");
    this.imageTargets.map((x) => {
      if (imageIds.includes(x.value)) {
        x.checked = true;
      } else {
        x.checked = false;
      }
    });
  }

  updateCount() {
    this.countTarget.innerHTML = this.uniqueArr.length;
  }

  send = (e) => {
    console.log(`Submit event: ${JSON.stringify(e)}`);
    console.log(`this.searchOutlet ${this.searchOutlet.value}`);

    clearTimeout(this.timeout);
    this.timeout = setTimeout(() => {
      this.element.requestSubmit();
    }, 200);
  };
}
