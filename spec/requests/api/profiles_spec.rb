require "rails_helper"

RSpec.describe "API::Profiles", type: :request do
  describe "POST /api/profiles (MySpeak ID limit)" do
    # New signups land on Free (the no-CC basic_trial soft trial was removed,
    # drafts/drop-basic-trial-option-a.md), so the base factory is already Free.
    let(:free_user) { FactoryBot.create(:user) }
    let(:pro_user) { FactoryBot.create(:user, plan_type: "pro") }

    let(:create_params) do
      { profile: { username: "pat-#{SecureRandom.hex(2)}" } }
    end

    context "as a Free user" do
      it "allows creating the first MySpeak ID" do
        expect {
          post "/api/profiles", params: create_params, headers: auth_headers(free_user)
        }.to change { Profile.where(profileable: free_user).count }.by(1)
        expect(response).to have_http_status(:created)
      end

      it "rejects the second MySpeak ID with 403 and a clear error code" do
        Profile.create!(
          profileable: free_user,
          username: "first-#{SecureRandom.hex(2)}",
          slug: "first-#{SecureRandom.hex(2)}",
        )

        post "/api/profiles", params: create_params, headers: auth_headers(free_user)

        expect(response).to have_http_status(:forbidden)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("myspeak_id_limit_reached")
        expect(body["limit"]).to eq(1)
        expect(body["count"]).to eq(1)
        expect(body["message"]).to include("Free")
      end

      it "counts a Profile attached to one of the user's communicator accounts toward the limit" do
        child = FactoryBot.create(:child_account, user: free_user, owner: free_user)
        Profile.create!(
          profileable: child,
          username: "child-#{SecureRandom.hex(2)}",
          slug: "child-#{SecureRandom.hex(2)}",
        )

        post "/api/profiles", params: create_params, headers: auth_headers(free_user)
        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)["error"]).to eq("myspeak_id_limit_reached")
      end
    end

    context "as a Pro user" do
      it "is not limited" do
        Profile.create!(
          profileable: pro_user,
          username: "first-#{SecureRandom.hex(2)}",
          slug: "first-#{SecureRandom.hex(2)}",
        )

        expect {
          post "/api/profiles", params: create_params, headers: auth_headers(pro_user)
        }.to change { Profile.where(profileable: pro_user).count }.by(1)
        expect(response).to have_http_status(:created)
      end
    end

    context "as an admin on the Free plan" do
      it "bypasses the limit" do
        admin = FactoryBot.create(:user, role: "admin")
        admin.update_columns(plan_type: "free", created_at: 30.days.ago)
        Profile.create!(
          profileable: admin,
          username: "first-#{SecureRandom.hex(2)}",
          slug: "first-#{SecureRandom.hex(2)}",
        )

        expect {
          post "/api/profiles", params: create_params, headers: auth_headers(admin)
        }.to change { Profile.where(profileable: admin).count }.by(1)
        expect(response).to have_http_status(:created)
      end
    end
  end

  describe "PUT /api/profiles/:id (slug edit)" do
    let(:owner) { FactoryBot.create(:user) }
    let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner) }
    let!(:profile) do
      p = Profile.new(profileable: child, username: "river-stone", slug: "river-stone")
      p.save!
      p
    end

    before do
      # generate_attachments! shells out to Grover/puppeteer to render the
      # safety ID card and device tag. Not what these specs are about and
      # not available on CI. The onboarding spec stubs this identically.
      allow_any_instance_of(Profile).to receive(:generate_attachments!).and_return(true)
    end

    def put_slug(value, as: owner)
      put "/api/profiles/#{profile.id}",
          params: { profile: { slug: value } },
          headers: auth_headers(as)
    end

    context "happy path" do
      it "accepts a fresh slug, updates the record, and records slug_changed_at" do
        put_slug("brand-new-link")
        expect(response).to have_http_status(:ok)
        profile.reload
        expect(profile.slug).to eq("brand-new-link")
        expect(profile.slug_changed_at).to be_present
      end

      it "ignores a slug change when the value matches the current slug" do
        # No 422 even though slug_changed_at would normally block re-edit; the
        # request is a no-op at the slug level.
        profile.update_columns(slug_changed_at: 1.day.ago)
        put_slug("river-stone")
        expect(response).to have_http_status(:ok)
      end
    end

    context "7-day lockout" do
      before { profile.update_columns(slug_changed_at: 1.day.ago) }

      it "returns 422 slug_locked with next_edit_at" do
        put_slug("different-link")
        expect(response).to have_http_status(:unprocessable_content)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("slug_locked")
        expect(body["next_edit_at"]).to be_present
      end

      it "admins bypass the lockout" do
        admin = FactoryBot.create(:user, role: "admin")
        put_slug("admin-pick", as: admin)
        expect(response).to have_http_status(:ok)
        expect(profile.reload.slug).to eq("admin-pick")
      end
    end

    context "validation errors" do
      it "returns slug_invalid for bad format" do
        put_slug("Bad_Slug!!")
        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to eq("slug_invalid")
      end

      it "returns slug_reserved for reserved words" do
        put_slug("admin")
        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to eq("slug_reserved")
      end

      it "returns slug_taken when the slug belongs to another profile" do
        other_child = FactoryBot.create(:child_account, user: owner, owner: owner)
        Profile.new(profileable: other_child, username: "taken-name", slug: "taken-name").save!
        put_slug("taken-name")
        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to eq("slug_taken")
      end
    end
  end

  describe "GET /api/profiles/check_slug" do
    it "returns available: true for a fresh, well-formed slug" do
      get "/api/profiles/check_slug", params: { slug: "totally-fresh" }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).to include("available" => true, "reason" => "ok")
    end

    it "returns available: false / reason: format for blank input" do
      get "/api/profiles/check_slug", params: { slug: "" }
      body = JSON.parse(response.body)
      expect(body).to include("available" => false, "reason" => "format")
    end

    it "returns reason: reserved for reserved words" do
      get "/api/profiles/check_slug", params: { slug: "admin" }
      expect(JSON.parse(response.body)["reason"]).to eq("reserved")
    end

    it "returns reason: taken when the slug already exists" do
      user = FactoryBot.create(:user)
      child = FactoryBot.create(:child_account, user: user, owner: user)
      Profile.new(profileable: child, username: "river-stone", slug: "river-stone").save!

      get "/api/profiles/check_slug", params: { slug: "river-stone" }
      expect(JSON.parse(response.body)["reason"]).to eq("taken")
    end

    it "does not require authentication" do
      get "/api/profiles/check_slug", params: { slug: "anon-ok" }
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/profiles/public/:slug (no leak of sensitive fields)" do
    let(:owner) { FactoryBot.create(:user, email: "parent-leak@example.com") }
    let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Sky") }

    it "returns a public_page communicator_account without parent email, passcode, or claim tokens" do
      profile = Profile.new(profileable: child, username: "sky-page", slug: "sky-page")
      profile.profile_kind = "public_page"
      profile.save!

      get "/api/profiles/public/#{profile.slug}"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      account = body["communicator_account"]
      expect(account.keys).to contain_exactly("id", "name", "avatar_url", "voice", "boards")
      expect(response.body).not_to include(owner.email)
      expect(response.body).not_to include(child.passcode.to_s) if child.passcode.present?
      expect(account).not_to have_key("parent_email")
    end

    it "returns a safety_view without communicator_account or email for a safety profile" do
      profile = Profile.new(profileable: child, username: "sky-safe", slug: "sky-safe")
      profile.save! # default profile_kind is "safety"

      get "/api/profiles/public/#{profile.slug}"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).not_to have_key("communicator_account")
      expect(body).not_to have_key("email")
      expect(response.body).not_to include(owner.email)
    end
  end

  describe "GET /api/profiles/public/:slug (legacy slug fallback)" do
    let(:owner) { FactoryBot.create(:user) }
    let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Emma") }
    let!(:profile) do
      p = Profile.new(profileable: child, username: "emma-jones", slug: "emma-jones")
      p.save!
      # Simulate the random-slug migration.
      p.update_columns(legacy_slug: "emma-jones", slug: "s-k8x2mf", slug_type: "random")
      p
    end

    it "301-redirects an old legacy slug to the current random slug" do
      get "/api/profiles/public/emma-jones"
      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/api/profiles/public/s-k8x2mf")
    end

    it "serves the profile directly on its current random slug" do
      get "/api/profiles/public/s-k8x2mf"
      expect(response).to have_http_status(:ok)
    end

    it "404s a slug that matches neither slug nor legacy_slug" do
      get "/api/profiles/public/does-not-exist"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/profiles/check_slug (legacy slug collisions)" do
    it "reports a slug taken when it matches an existing legacy_slug" do
      user = FactoryBot.create(:user)
      child = FactoryBot.create(:child_account, user: user, owner: user)
      profile = Profile.new(profileable: child, username: "emma-jones", slug: "emma-jones").tap(&:save!)
      profile.update_columns(legacy_slug: "emma-jones", slug: "s-k8x2mf", slug_type: "random")

      get "/api/profiles/check_slug", params: { slug: "emma-jones" }
      expect(JSON.parse(response.body)["reason"]).to eq("taken")
    end
  end
end
