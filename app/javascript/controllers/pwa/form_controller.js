import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="pwa--form"
export default class extends Controller {
  connect() {
    // declare an indexedDB database, declare a boolean variable for the network status
    this.db = findOrCreateDB()
    this.onlineStatus = getOnlineStatusFromLocalStorage() === "true"
   }
   
   submit() {
   // we check again in case it changed just before the submission
     this.onlineStatus = (this.getOnlineStatusFromLocalStorage() === "true" ) 
     if (!this.onlineStatus) { event.preventDefault() }
   }
   
   async saveFormData() {
     this.onlineStatus = (this.getOnlineStatusFromLocalStorage() === "true" )
     if (!this.formValid()) { return } // check if form is valid before saving it
     if (!this.onlineStatus()) {
       // save record in IndexedDB
     }
   }
}
