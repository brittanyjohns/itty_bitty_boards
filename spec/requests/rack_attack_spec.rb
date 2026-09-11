require "rails_helper"

# Rate limiting (issue #30). Rack::Attack is disabled in the test env by
# default (so it doesn't perturb other request specs); this spec opts in and
# swaps in a fresh in-memory counter store per example, since the app's
# Rails.cache is :null_store in test and would never count.
RSpec.describe "Rack::Attack rate limiting", type: :request do
  around do |example|
    prev_enabled = Rack::Attack.enabled
    prev_store = Rack::Attack.cache.store

    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

    example.run

    Rack::Attack.cache.store = prev_store
    Rack::Attack.enabled = prev_enabled
  end

  describe "auth sign-in throttle (per IP)" do
    let(:limit) { Rack::Attack::LOGIN_LIMIT }

    # Distinct emails so only the per-IP rule (not the tighter per-email rule)
    # accumulates.
    def failed_login(n)
      post "/api/v1/users/sign_in",
        params: { email: "attacker#{n}@example.com", password: "wrong" },
        as: :json
    end

    it "lets a normal request rate through" do
      3.times { |i| failed_login(i) }
      expect(response).to have_http_status(:unauthorized) # 401, not 429
    end

    it "returns 429 once the burst passes the limit" do
      limit.times { |i| failed_login(i) }
      expect(response).not_to have_http_status(:too_many_requests)

      failed_login(limit) # one over
      expect(response).to have_http_status(:too_many_requests)
    end

    it "returns a clean 429 with Retry-After and no internals leaked" do
      (limit + 1).times { |i| failed_login(i) }

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"].to_i).to be > 0

      body = JSON.parse(response.body)
      expect(body["error"]).to eq("rate_limited")
      # Body must not leak which rule matched or any stack/internal detail.
      expect(response.body).not_to match(/login|throttle|rack|attack|backtrace/i)
    end
  end

  describe "auth sign-in throttle (per email)" do
    it "throttles repeated attempts against a single account" do
      email_limit = Rack::Attack::LOGIN_EMAIL_LIMIT

      email_limit.times do
        post "/api/v1/users/sign_in",
          params: { email: "victim@example.com", password: "guess" },
          as: :json
      end
      expect(response).not_to have_http_status(:too_many_requests)

      post "/api/v1/users/sign_in",
        params: { email: "victim@example.com", password: "guess" },
        as: :json
      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "password reset throttle (per IP)" do
    it "returns 429 past the limit" do
      limit = Rack::Attack::PASSWORD_RESET_LIMIT

      limit.times do
        post "/api/v1/forgot_password", params: { email: "someone@example.com" }, as: :json
      end
      expect(response).not_to have_http_status(:too_many_requests)

      post "/api/v1/forgot_password", params: { email: "someone@example.com" }, as: :json
      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "token-access lookup throttle (per IP)" do
    it "returns 429 past the limit" do
      limit = Rack::Attack::TOKEN_LIMIT

      limit.times { get "/api/temp-login/deadbeef" }
      expect(response).not_to have_http_status(:too_many_requests)

      get "/api/temp-login/deadbeef"
      expect(response).to have_http_status(:too_many_requests)
    end

    # verify_email takes its token as a query param, not a path segment, so
    # the path has no trailing slash — unlike temp-login/communicator_claims.
    # A regex that forgot this would silently never match and leave the
    # endpoint unprotected while looking protected.
    it "throttles GET /api/verify_email (query-string token, no trailing slash) past the limit" do
      limit = Rack::Attack::TOKEN_LIMIT

      limit.times { get "/api/verify_email", params: { token: "deadbeef" } }
      expect(response).not_to have_http_status(:too_many_requests)

      get "/api/verify_email", params: { token: "deadbeef" }
      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "TOKEN_ACCESS_PATHS regex" do
    it "matches /api/verify_email even though it has no trailing slash" do
      expect(Rack::Attack::TOKEN_ACCESS_PATHS).to match("/api/verify_email")
    end

    it "still matches the path-segment token endpoints" do
      expect(Rack::Attack::TOKEN_ACCESS_PATHS).to match("/api/temp-login/abc123")
      expect(Rack::Attack::TOKEN_ACCESS_PATHS).to match("/api/communicator_claims/abc123")
    end

    it "does not match unrelated or lookalike paths" do
      expect(Rack::Attack::TOKEN_ACCESS_PATHS).not_to match("/api/verify_emailxxx")
      expect(Rack::Attack::TOKEN_ACCESS_PATHS).not_to match("/api/verify_email/")
      expect(Rack::Attack::TOKEN_ACCESS_PATHS).not_to match("/api/resend_email_verification")
    end
  end

  describe "signup throttle (per IP)" do
    let(:limit) { Rack::Attack::SIGNUP_LIMIT }

    # The Stripe gem raises Stripe::AuthenticationError client-side when no API
    # key is configured, before any request is made — so the WebMock stub for
    # api.stripe.com never sees it. CI has no key. Same stub as auth_spec.rb.
    before { allow(User).to receive(:create_stripe_customer).and_return("cus_test") }

    # Distinct emails so failures come from the throttle, not uniqueness.
    def signup(n)
      post "/api/v1/users",
        params: { email: "signup#{n}@example.com", password: "password123",
                  password_confirmation: "password123" },
        as: :json
    end

    it "lets a normal signup rate through" do
      3.times { |i| signup(i) }
      expect(response).not_to have_http_status(:too_many_requests)
    end

    it "returns 429 once the burst passes the limit" do
      limit.times { |i| signup(i) }
      expect(response).not_to have_http_status(:too_many_requests)

      signup(limit) # one over
      expect(response).to have_http_status(:too_many_requests)
    end

    it "throttles the email-only signup path on the same counter" do
      limit.times { |i| signup(i) }

      post "/api/v1/users/email_signup", params: { email: "over@example.com" }, as: :json
      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "AI / audio generation throttle" do
    # Unauthenticated requests still pass through Rack::Attack (middleware runs
    # before the controller's auth), so we can exercise the throttle cheaply —
    # each request 401s at the controller, but the throttle counter still ticks.
    it "throttles the /generate* surface past the limit" do
      limit = Rack::Attack::AI_LIMIT

      limit.times { post "/api/images/generate", params: {}, as: :json }
      expect(response).not_to have_http_status(:too_many_requests)

      post "/api/images/generate", params: {}, as: :json
      expect(response).to have_http_status(:too_many_requests)
    end

    it "buckets per user via the auth token, not shared globally" do
      env_for = ->(token) do
        Rack::Attack.user_discriminator(
          Rack::Request.new(Rack::MockRequest.env_for("/api/images/generate", "HTTP_AUTHORIZATION" => "Bearer #{token}"))
        )
      end

      key_a = env_for.call("token-aaa")
      key_b = env_for.call("token-bbb")

      expect(key_a).to start_with("user:")
      expect(key_a).not_to eq(key_b)          # different users → different buckets
      expect(key_a).not_to include("token-aaa") # raw token never used as the key
    end

    it "falls back to an IP bucket when unauthenticated" do
      key = Rack::Attack.user_discriminator(
        Rack::Request.new(Rack::MockRequest.env_for("/api/images/generate", "REMOTE_ADDR" => "9.9.9.9"))
      )
      expect(key).to eq("ip:9.9.9.9")
    end
  end

  # Issue #912 — the two public, unauthenticated lead-capture writes.
  describe "public lead capture / contest entry throttles" do
    def mock_req(path, body, content_type: "application/json")
      Rack::Request.new(
        Rack::MockRequest.env_for(
          path,
          method: "POST",
          "CONTENT_TYPE" => content_type,
          input: body
        )
      )
    end

    describe "LEAD_WRITE_PATHS" do
      it "matches both throttled paths" do
        expect(Rack::Attack::LEAD_WRITE_PATHS).to match("/api/download_leads")
        expect(Rack::Attack::LEAD_WRITE_PATHS).to match("/api/events/ctg-2026/save_entry")
      end

      it "does not match lookalike paths" do
        expect(Rack::Attack::LEAD_WRITE_PATHS).not_to match("/api/download_leadsx")
        expect(Rack::Attack::LEAD_WRITE_PATHS).not_to match("/api/download_leads/export")
        expect(Rack::Attack::LEAD_WRITE_PATHS).not_to match("/api/events/ctg-2026")
        expect(Rack::Attack::LEAD_WRITE_PATHS).not_to match("/api/admin/events")
      end
    end

    describe ".lead_email (the per-email discriminator)" do
      it "reads the WRAPPED download_lead key — wrap_parameters is off in this app" do
        req = mock_req("/api/download_leads", { download_lead: { email: "a@example.com" } }.to_json)
        expect(Rack::Attack.lead_email(req)).to eq("a@example.com")
      end

      it "reads the wrapped contest_entry key" do
        req = mock_req("/api/events/ctg/save_entry", { contest_entry: { email: "b@example.com" } }.to_json)
        expect(Rack::Attack.lead_email(req)).to eq("b@example.com")
      end

      it "normalizes case and surrounding whitespace onto one bucket" do
        messy = mock_req("/api/download_leads", { download_lead: { email: "  Booth.Visitor@Example.COM \n" } }.to_json)
        clean = mock_req("/api/download_leads", { download_lead: { email: "booth.visitor@example.com" } }.to_json)

        expect(Rack::Attack.lead_email(messy)).to eq("booth.visitor@example.com")
        expect(Rack::Attack.lead_email(messy)).to eq(Rack::Attack.lead_email(clean))
      end

      # A malformed or missing body must never raise inside a throttle block —
      # that would 500 a public endpoint instead of throttling it.
      it "returns nil (never raises) on malformed, empty, or unwrapped bodies" do
        expect(Rack::Attack.lead_email(mock_req("/api/download_leads", "{not json"))).to be_nil
        expect(Rack::Attack.lead_email(mock_req("/api/download_leads", ""))).to be_nil
        expect(Rack::Attack.lead_email(mock_req("/api/download_leads", "[1,2,3]"))).to be_nil
        expect(Rack::Attack.lead_email(mock_req("/api/download_leads", { email: "top@level.com" }.to_json))).to be_nil
        expect(Rack::Attack.lead_email(mock_req("/api/download_leads", { download_lead: "nope" }.to_json))).to be_nil
        expect(Rack::Attack.lead_email(mock_req("/api/download_leads", { download_lead: {} }.to_json))).to be_nil
      end
    end

    describe "leads/ip (per IP)" do
      let(:limit) { Rack::Attack::LEADS_IP_LIMIT }

      # Distinct emails so only the per-IP rule accumulates (the per-email rule
      # is far tighter).
      def submit_lead(n)
        post "/api/download_leads",
          params: { download_lead: { email: "booth#{n}@example.com", source: "ctg" } },
          as: :json
      end

      # THE booth test. Everyone at the conference shares one hotel/venue Wi-Fi
      # public IP, so a burst under the limit from a single IP must sail through.
      it "never throttles a burst under the limit from one shared IP" do
        (limit - 1).times { |i| submit_lead(i) }

        expect(response).not_to have_http_status(:too_many_requests)
        expect(response).to have_http_status(:created)
      end

      it "is generous by default: at least 60 per 10 minutes" do
        expect(Rack::Attack::LEADS_IP_LIMIT).to be >= 60
        expect(Rack::Attack::LEADS_IP_PERIOD).to be >= 600
      end

      it "returns 429 once the burst passes the limit" do
        limit.times { |i| submit_lead(i) }
        expect(response).not_to have_http_status(:too_many_requests)

        submit_lead(limit) # one over
        expect(response).to have_http_status(:too_many_requests)
      end

      # Both paths share the one per-IP bucket, so a flood that switches
      # endpoints halfway is still bounded.
      it "counts save_entry against the same per-IP bucket as download_leads" do
        event = create(:event)

        limit.times { |i| submit_lead(i) }
        expect(response).not_to have_http_status(:too_many_requests)

        post "/api/events/#{event.slug}/save_entry",
          params: { contest_entry: { name: "Over Limit", email: "over@example.com" } },
          as: :json
        expect(response).to have_http_status(:too_many_requests)
      end
    end

    describe "leads/email (per normalized email)" do
      let(:limit) { Rack::Attack::LEADS_EMAIL_LIMIT }

      def submit_lead(email)
        post "/api/download_leads",
          params: { download_lead: { email: email, source: "ctg" } },
          as: :json
      end

      it "is small by default" do
        expect(limit).to be <= 5
      end

      it "returns 429 once one address is hammered past the limit" do
        limit.times { submit_lead("hammered@example.com") }
        expect(response).not_to have_http_status(:too_many_requests)

        submit_lead("hammered@example.com")
        expect(response).to have_http_status(:too_many_requests)
      end

      # Case and whitespace variants must land in ONE bucket, or the rule is
      # trivially sidestepped.
      it "counts case and whitespace variants of one address together" do
        limit.times { submit_lead("victim@example.com") }
        expect(response).not_to have_http_status(:too_many_requests)

        submit_lead("  VICTIM@Example.Com  ")
        expect(response).to have_http_status(:too_many_requests)
      end

      it "does not leak which rule matched in the 429 body" do
        (limit + 1).times { submit_lead("noisy@example.com") }

        expect(response).to have_http_status(:too_many_requests)
        expect(response.headers["Retry-After"].to_i).to be > 0
        expect(JSON.parse(response.body)["error"]).to eq("rate_limited")
        expect(response.body).not_to match(/lead|email|throttle|rack|attack/i)
      end

      # Different visitors at the booth each get their own bucket.
      it "buckets distinct addresses separately" do
        limit.times { submit_lead("first@example.com") }

        submit_lead("second@example.com")
        expect(response).not_to have_http_status(:too_many_requests)
      end
    end
  end

  describe "health-check safelist" do
    it "never throttles /up even under a heavy burst" do
      (Rack::Attack::LOGIN_LIMIT * 3).times { get "/up" }
      expect(response).not_to have_http_status(:too_many_requests)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "export throttle (per user)" do
    let(:user) { create(:user) }
    let!(:board) { create(:board, user: user) }
    let(:limit) { Rack::Attack::EXPORT_LIMIT }

    before do
      allow_any_instance_of(BoardImage).to receive(:tile_image_url).and_return("https://example.test/i.png")
      allow_any_instance_of(BoardImage).to receive(:audio_url).and_return(nil)
    end

    def request_export
      post "/api/boards/#{board.id}/export_package", headers: auth_headers(user)
    end

    def request_download
      get "/api/boards/#{board.id}/download_obf", headers: auth_headers(user)
    end

    it "lets a normal request rate through" do
      3.times { request_export }
      expect(response).not_to have_http_status(:too_many_requests)
    end

    it "returns 429 once the burst passes the per-user limit" do
      limit.times { request_export }
      expect(response).not_to have_http_status(:too_many_requests)

      request_export
      expect(response).to have_http_status(:too_many_requests)
    end

    # GET download_obf (the synchronous .obf path) previously matched no
    # throttle at all — Task 1 capped it per-request (200 tiles/20MB) but
    # never bounded repeated requests. It now shares the export/user bucket.
    it "throttles GET download_obf the same way as POST export_package" do
      limit.times { request_download }
      expect(response).not_to have_http_status(:too_many_requests)

      request_download
      expect(response).to have_http_status(:too_many_requests)
    end

    it "counts download_obf and export_package against the same shared bucket" do
      limit.times { request_download }
      expect(response).not_to have_http_status(:too_many_requests)

      request_export
      expect(response).to have_http_status(:too_many_requests)
    end
  end
end
