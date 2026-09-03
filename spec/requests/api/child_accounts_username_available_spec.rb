# frozen_string_literal: true

require "rails_helper"

# Communicator usernames are globally unique, so every common first name is
# already someone's. This endpoint lets the create form ask BEFORE the parent
# reaches the end of the wizard and eats a 422 on the name of their child.
RSpec.describe "API::ChildAccounts#username_available", type: :request do
  let(:user) { create(:user, name: "Maya Rivera", created_at: 2.months.ago) }
  let(:stranger) { create(:user, created_at: 2.months.ago) }

  def check(username, as: user)
    get "/api/child_accounts/username_available",
        params: { username: username },
        headers: auth_headers(as)
    JSON.parse(response.body)
  end

  it "reports a free username as available with no suggestions" do
    body = check("leo")

    expect(response).to have_http_status(:ok)
    expect(body).to include("username" => "leo", "available" => true, "suggestions" => [])
  end

  it "reports a taken username as unavailable" do
    create(:child_account, user: stranger, owner: stranger, username: "leo")

    body = check("leo")

    expect(response).to have_http_status(:ok)
    expect(body["username"]).to eq("leo")
    expect(body["available"]).to be(false)
  end

  it "is taken even when the owner is a stranger, and says nothing about who owns it" do
    create(:child_account, user: stranger, owner: stranger, username: "leo")

    body = check("leo")

    expect(body["available"]).to be(false)
    expect(body.keys).to match_array(%w[username available suggestions])
    expect(response.body).not_to include(stranger.email)
    expect(response.body).not_to include(stranger.id.to_s)
  end

  describe "suggestions" do
    before { create(:child_account, user: stranger, owner: stranger, username: "leo") }

    it "returns 1-3 alternatives, each confirmed free" do
      body = check("leo")

      suggestions = body["suggestions"]
      expect(suggestions.size).to be_between(1, 3)
      expect(suggestions).to all(start_with("leo"))
      expect(suggestions).not_to include("leo")
      suggestions.each do |candidate|
        expect(ChildAccount.exists?(username: candidate)).to be(false)
      end
    end

    it "never suggests a name that is itself taken" do
      # Pre-take every deterministic candidate the helper can offer, so the only
      # answers left are ones it had to confirm free.
      %w[leo-r leo-2026 leo2 leo3 leo-1].each do |name|
        create(:child_account, user: stranger, owner: stranger, username: name)
      end

      body = check("leo")

      expect(body["suggestions"]).to be_present

      body["suggestions"].each do |candidate|
        expect(ChildAccount.exists?(username: candidate)).to be(false)
      end
    end
  end

  describe "normalization" do
    it "answers about the normalized username and echoes what it checked" do
      create(:child_account, user: stranger, owner: stranger, username: "leo")

      body = check("  Leo  ")

      expect(body["username"]).to eq("leo")
      expect(body["available"]).to be(false)
    end

    it "parameterizes the way the create path does" do
      body = check("Leo Rivera")

      expect(body["username"]).to eq("leo-rivera")
      expect(body["available"]).to be(true)
    end
  end

  describe "blank input" do
    it "is unavailable rather than a crash" do
      body = check("")

      expect(response).to have_http_status(:ok)
      expect(body).to eq("username" => "", "available" => false, "suggestions" => [])
    end

    it "handles a missing param" do
      get "/api/child_accounts/username_available", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["available"]).to be(false)
    end

    it "handles input that normalizes to nothing" do
      body = check("!!!")

      expect(response).to have_http_status(:ok)
      expect(body["available"]).to be(false)
    end
  end

  it "requires a signed-in caller — the endpoint reveals whether a name exists" do
    get "/api/child_accounts/username_available", params: { username: "leo" }

    expect(response).to have_http_status(:unauthorized)
  end

  # `resources :child_accounts` also serves GET /api/child_accounts/:id, so the
  # collection route has to win — otherwise "username_available" is looked up as
  # an id and the endpoint 404s.
  it "is not shadowed by the :id show route" do
    body = check("leo")

    expect(response).to have_http_status(:ok)
    expect(body).to have_key("available")
  end
end
