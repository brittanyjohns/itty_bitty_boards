# frozen_string_literal: true

module StripeHelpers
  # Mimic Stripe::StripeObject: supports dot access and [] access
  def stripe_obj(hash)
    obj = OpenStruct.new(hash)
    def obj.[](k) = to_h[k]
    obj
  end

  def stripe_event(type:, object:)
    {
      "id" => "evt_#{SecureRandom.hex(6)}",
      "type" => type,
      "data" => { "object" => object },
    }
  end

  def header_with_signature
    # We stub construct_event so the actual signature doesn't matter
    { "HTTP_STRIPE_SIGNATURE" => "t=123,v1=fakesig" }
  end

  def post_webhook(json_body, headers = {})
    post "/api/webhooks", params: json_body, headers: headers.merge({ "CONTENT_TYPE" => "application/json" })
  end
end
