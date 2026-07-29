require "rails_helper"

RSpec.describe GoogleIdTokenVerifier do
  around do |example|
    original = ENV["GOOGLE_OAUTH_CLIENT_ID"]
    ENV["GOOGLE_OAUTH_CLIENT_ID"] = "test-client-id"
    example.run
    ENV["GOOGLE_OAUTH_CLIENT_ID"] = original
  end

  def stub_tokeninfo(status: 200, body: {})
    response = instance_double(Net::HTTPOK, is_a?: status == 200, body: body.to_json)
    allow(Net::HTTP).to receive(:get_response).and_return(response)
  end

  it "returns nil for a blank token" do
    expect(described_class.verify(nil)).to be_nil
    expect(described_class.verify("")).to be_nil
  end

  it "returns nil when GOOGLE_OAUTH_CLIENT_ID is not configured" do
    ENV["GOOGLE_OAUTH_CLIENT_ID"] = nil
    expect(described_class.verify("some-token")).to be_nil
  end

  it "returns a Result when the token is valid and aud matches" do
    stub_tokeninfo(body: { "aud" => "test-client-id", "sub" => "111", "email" => "User@Example.com", "email_verified" => "true" })

    result = described_class.verify("some-token")

    expect(result.sub).to eq("111")
    expect(result.email).to eq("user@example.com")
  end

  it "returns nil when aud does not match our client id" do
    stub_tokeninfo(body: { "aud" => "someone-elses-client-id", "sub" => "111", "email" => "user@example.com", "email_verified" => "true" })

    expect(described_class.verify("some-token")).to be_nil
  end

  it "returns nil when email_verified is false" do
    stub_tokeninfo(body: { "aud" => "test-client-id", "sub" => "111", "email" => "user@example.com", "email_verified" => "false" })

    expect(described_class.verify("some-token")).to be_nil
  end

  it "returns nil when Google responds with a non-2xx status" do
    response = instance_double(Net::HTTPBadRequest, is_a?: false)
    allow(Net::HTTP).to receive(:get_response).and_return(response)

    expect(described_class.verify("expired-token")).to be_nil
  end

  it "returns nil and does not raise on a network error" do
    allow(Net::HTTP).to receive(:get_response).and_raise(Timeout::Error)

    expect(described_class.verify("some-token")).to be_nil
  end
end
