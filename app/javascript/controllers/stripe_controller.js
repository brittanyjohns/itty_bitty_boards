// import { Controller } from "@hotwired/stimulus"

// // Connects to data-controller="stripe"
// export default class extends Controller {
//   connect() {
//     console.log("Hello, StripeController!", this.element.dataset);
//     const parameterized_email = this.element.dataset.stripeEmailValue;
//     this.pay_link_url = `https://buy.stripe.com/9AQdTgcLT1MR0XS9AA?prefilled_email=${parameterized_email}`
//   }

//   paylink() {
//     console.log("Pay link");
//     window.location.href = this.pay_link_url;
//   }
// }
