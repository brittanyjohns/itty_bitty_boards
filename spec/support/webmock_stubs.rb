PLACEHOLDER_IMAGE = Rails.root.join("public/placeholder.jpeg").read.freeze

def register_external_webmock_stubs!
  WebMock.stub_request(:any, /api\.stripe\.com/)
    .to_return(status: 200, headers: { "Content-Type" => "application/json" },
               body: { data: [], has_more: false, object: "list" }.to_json)

  WebMock.stub_request(:get, /ui-avatars\.com/)
    .to_return(status: 200, headers: { "Content-Type" => "image/png" }, body: PLACEHOLDER_IMAGE)

  WebMock.stub_request(:get, /robohash\.org/)
    .to_return(status: 200, headers: { "Content-Type" => "image/png" }, body: PLACEHOLDER_IMAGE)

  WebMock.stub_request(:get, /cloudfront\.net/)
    .to_return(status: 200, headers: { "Content-Type" => "image/png" }, body: PLACEHOLDER_IMAGE)

  WebMock.stub_request(:post, /posthog\.com/)
    .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

  WebMock.stub_request(:any, /api\.mailchimp\.com/)
    .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
end

RSpec.configure do |config|
  config.before(:all) do
    register_external_webmock_stubs!
  end

  config.before(:each) do
    register_external_webmock_stubs!
  end
end
