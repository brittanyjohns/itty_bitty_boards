# Default stubs for external APIs that callbacks/factories may hit.
# webmock/rspec resets stubs between examples, so these must run in
# before(:each) to survive across the suite.
PLACEHOLDER_IMAGE = Rails.root.join("public/placeholder.jpeg").read.freeze

RSpec.configure do |config|
  config.before(:each) do
    # Stripe API
    stub_request(:any, /api\.stripe\.com/)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { data: [], has_more: false, object: "list" }.to_json
      )

    # UI Avatars (Profile#set_fake_avatar)
    stub_request(:get, /ui-avatars\.com/)
      .to_return(status: 200, headers: { "Content-Type" => "image/png" }, body: PLACEHOLDER_IMAGE)

    # Robohash (Profile#set_fake_avatar)
    stub_request(:get, /robohash\.org/)
      .to_return(status: 200, headers: { "Content-Type" => "image/png" }, body: PLACEHOLDER_IMAGE)

    # CloudFront / S3 — image downloads
    stub_request(:get, /cloudfront\.net/)
      .to_return(status: 200, headers: { "Content-Type" => "image/png" }, body: PLACEHOLDER_IMAGE)

    # PostHog capture
    stub_request(:post, /posthog\.com/)
      .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

    # Mailchimp API
    stub_request(:any, /api\.mailchimp\.com/)
      .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
  end
end
