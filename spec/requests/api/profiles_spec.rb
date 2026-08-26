require "rails_helper"

RSpec.describe "API::Profiles", type: :request do
  describe "POST /api/profiles (one Public page per user)" do
    # New signups land on Free (the no-CC basic_trial soft trial was removed,
    # drafts/drop-basic-trial-option-a.md), so the base factory is already Free.
    let(:free_user) { FactoryBot.create(:user) }
    let(:pro_user) { FactoryBot.create(:user, plan_type: "pro") }

    let(:create_params) do
      { profile: { username: "pat-#{SecureRandom.hex(2)}" } }
    end

    def existing_page_for(user)
      Profile.create!(
        profileable: user,
        username: "first-#{SecureRandom.hex(2)}",
        slug: "first-#{SecureRandom.hex(2)}",
      )
    end

    context "as a Free user" do
      it "allows creating the first Public page" do
        expect {
          post "/api/profiles", params: create_params, headers: auth_headers(free_user)
        }.to change { Profile.where(profileable: free_user).count }.by(1)
        expect(response).to have_http_status(:created)
      end

      it "rejects a second Public page with 409 and points at the existing one" do
        existing = existing_page_for(free_user)

        expect {
          post "/api/profiles", params: create_params, headers: auth_headers(free_user)
        }.not_to change { Profile.where(profileable: free_user).count }

        expect(response).to have_http_status(:conflict)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("public_page_exists")
        expect(body["profile_id"]).to eq(existing.id)
        expect(body["slug"]).to eq(existing.slug)
      end

      # Regression for #761. Every communicator auto-mints a Profile
      # (ChildAccount#create_profile!), and that used to burn the user's only
      # MySpeak slot — so a Free user who added one communicator could never
      # create their own page. A communicator's MySpeak page is free on every
      # plan; the communicator SLOT is the quota, not a Profile count.
      it "does not count a communicator's MySpeak page against the user's page" do
        child = FactoryBot.create(:child_account, user: free_user, owner: free_user)
        Profile.create!(
          profileable: child,
          username: "child-#{SecureRandom.hex(2)}",
          slug: "child-#{SecureRandom.hex(2)}",
        )

        expect {
          post "/api/profiles", params: create_params, headers: auth_headers(free_user)
        }.to change { Profile.where(profileable: free_user).count }.by(1)
        expect(response).to have_http_status(:created)
      end
    end

    # One page per user is structural (User `has_one :profile`), so it holds on
    # every plan — a paid user does not get a second, unreachable row.
    context "as a Pro user" do
      it "still gets only one Public page" do
        existing_page_for(pro_user)

        post "/api/profiles", params: create_params, headers: auth_headers(pro_user)

        expect(response).to have_http_status(:conflict)
        expect(JSON.parse(response.body)["error"]).to eq("public_page_exists")
      end
    end

    context "as an admin" do
      it "still gets only one Public page" do
        admin = FactoryBot.create(:user, role: "admin")
        admin.update_columns(plan_type: "free", created_at: 30.days.ago)
        existing_page_for(admin)

        post "/api/profiles", params: create_params, headers: auth_headers(admin)

        expect(response).to have_http_status(:conflict)
        expect(JSON.parse(response.body)["error"]).to eq("public_page_exists")
      end
    end
  end

  # Uniqueness indexes are per-column, so nothing at the DB level stopped one
  # profile's `slug` equalling another's `permanent_slug` — and `resolve_slug`
  # prefers `slug`, so the claimant WON and the victim's printed QR resolved to
  # the claimant's page. The generated shape is reserved to close that.
  describe "claiming a slug in the generated namespace" do
    let(:owner) { FactoryBot.create(:user) }
    let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner) }
    let!(:victim) do
      Profile.new(profileable: child, username: "river-stone").tap(&:save!)
    end
    let(:stranger) { FactoryBot.create(:user) }

    it "refuses to create a page on another profile's permanent address" do
      printed = victim.permanent_slug

      post "/api/profiles",
           params: { profile: { username: "pat-x", slug: printed } },
           headers: auth_headers(stranger)

      expect(response).to have_http_status(:unprocessable_content)
      # The printed address still resolves to the profile it belongs to.
      expect(Profile.resolve_slug(printed)).to eq([victim, :permanent])
    end

    it "refuses to rename an existing page onto one" do
      page = Profile.new(profileable: stranger, profile_kind: "public_page", username: "pat-x")
                    .tap(&:save!)

      put "/api/profiles/#{page.id}",
          params: { profile: { slug: victim.permanent_slug } },
          headers: auth_headers(stranger)

      expect(response).to have_http_status(:unprocessable_content)
      expect(Profile.resolve_slug(victim.permanent_slug)).to eq([victim, :permanent])
    end

    # check_slug must not become an oracle for which generated slugs exist —
    # a permanent one can never be rotated away once known.
    it "answers check_slug with 'reserved', revealing nothing about what exists" do
      get "/api/profiles/check_slug", params: { slug: victim.permanent_slug }
      taken = JSON.parse(response.body)

      get "/api/profiles/check_slug", params: { slug: "s-zzzzzz" }
      free = JSON.parse(response.body)

      # Identical verdicts for one that exists and one that doesn't. (The body
      # also echoes the caller's own slug, which tells them nothing.)
      expect(taken["reason"]).to eq("reserved")
      expect(taken.slice("available", "reason")).to eq(free.slice("available", "reason"))
    end
  end

  describe "profiles routing", type: :routing do
    # API::ProfilesController defines no destroy/new/edit; a bare `resources`
    # routed these at missing actions (ActionNotFound => a 500). They now fall
    # through to the catch-all, which is a clean 404.
    it "sends the actions the controller never defined to the catch-all 404" do
      expect(delete: "/api/profiles/1").to route_to(
        controller: "error", action: "not_found", path: "api/profiles/1",
      )
      expect(get: "/api/profiles/1/edit").to route_to(
        controller: "error", action: "not_found", path: "api/profiles/1/edit",
      )
      # /new now falls through to #show, which 404s on the lookup — also fine.
      expect(get: "/api/profiles/new").to route_to(
        "api/profiles#show", id: "new", format: :json,
      )
    end

    it "still routes the actions the controller does define" do
      expect(get: "/api/profiles").to route_to("api/profiles#index", format: :json)
      expect(post: "/api/profiles").to route_to("api/profiles#create", format: :json)
      expect(get: "/api/profiles/1").to route_to("api/profiles#show", id: "1", format: :json)
      expect(put: "/api/profiles/1").to route_to("api/profiles#update", id: "1", format: :json)
      expect(get: "/api/profiles/check_slug").to route_to("api/profiles#check_slug", format: :json)
      expect(get: "/api/account/profiles/me").to route_to("api/account/profiles#me", format: :json)
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

    # A random safety slug is locked forever, not until a date — the 7-day
    # copy is built around a `next_edit_at` this case doesn't have, so it
    # rendered "You can change your link again on ." (issue #774).
    context "a random safety slug" do
      let!(:profile) do
        Profile.new(profileable: child, username: "river-stone").tap(&:save!)
      end

      it "is permanent, and says so instead of promising a date" do
        expect(profile.slug_type).to eq("random")

        put_slug("river-stone")

        expect(response).to have_http_status(:unprocessable_content)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("slug_permanent")
        expect(body["message"]).to include("randomly generated")
        expect(body).not_to have_key("next_edit_at")
        expect(profile.reload.slug).to match(/\As-[a-z0-9]{6}\z/)
      end

      it "reports itself as locked on api_view so the form can disable the field" do
        view = profile.api_view(owner)
        expect(view[:slug_editable]).to be false
        expect(view[:slug_type]).to eq("random")
        expect(view[:slug_editable_at]).to be_nil
      end

      it "still lets an admin re-key it" do
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

  # An unguessable link is still a bearer token: whoever it was shared with
  # keeps access until the address changes. Renaming is refused for a safety
  # page (that's the point of the random slug), so revocation is its own action.
  describe "POST /api/profiles/:id/rotate_slug" do
    let(:owner) { FactoryBot.create(:user) }
    let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner) }
    let!(:profile) do
      Profile.new(profileable: child, username: "river-stone").tap(&:save!)
    end

    before do
      allow_any_instance_of(Profile).to receive(:generate_attachments!).and_return(true)
    end

    def rotate(as: owner)
      post "/api/profiles/#{profile.id}/rotate_slug", headers: auth_headers(as)
    end

    it "mints a new random slug and reports the one it replaced" do
      old_slug = profile.slug

      rotate

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["previous_slug"]).to eq(old_slug)
      expect(body["slug"]).to match(/\As-[a-z0-9]{6}\z/)
      expect(body["slug"]).not_to eq(old_slug)
      expect(profile.reload.slug_type).to eq("random")
    end

    # The point of rotating is that the old address STOPS working. Keeping it
    # as legacy_slug — which is right for a rename — would leave the leaked
    # link 301ing to the new one, i.e. not revoked at all.
    it "kills the old address instead of preserving it" do
      old_slug = profile.slug
      rotate

      expect(profile.reload.legacy_slug).to be_nil

      get "/api/profiles/public/#{old_slug}"
      expect(response).to have_http_status(:not_found)
    end

    it "clears a legacy slug the profile was already carrying" do
      profile.update_columns(legacy_slug: "river-stone")

      rotate

      expect(profile.reload.legacy_slug).to be_nil
      get "/api/profiles/public/river-stone"
      expect(response).to have_http_status(:not_found)
    end

    # The whole reason permanent_slug exists: revoking a link must not cost a
    # reprint of the tag stuck to the child's iPad.
    it "leaves the printed address untouched and still resolving" do
      permanent = profile.permanent_slug
      expect(permanent).to be_present

      rotate

      expect(profile.reload.permanent_slug).to eq(permanent)
      get "/api/profiles/public/#{permanent}"
      expect(response).to have_http_status(:ok)
    end

    it "regenerates the safety card once, for a tag printed before the column existed" do
      expect {
        rotate
      }.to have_enqueued_job(RegenerateSafetyCardsJob).with(profile.id)
    end

    it "assigns a permanent slug first when the backfill hasn't reached the row" do
      profile.update_columns(permanent_slug: nil)

      rotate

      expect(profile.reload.permanent_slug).to match(/\As-[a-z0-9]{6}\z/)
    end

    it "refuses someone who doesn't own the communicator" do
      stranger = FactoryBot.create(:user)
      old_slug = profile.slug

      rotate(as: stranger)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("not_owner")
      expect(profile.reload.slug).to eq(old_slug)
    end

    it "requires authentication" do
      post "/api/profiles/#{profile.id}/rotate_slug"
      expect(response).to have_http_status(:unauthorized)
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

  # The public MySpeak page offers a "Sign in as {name}" CTA, but only when the
  # communicator actually has a working private login. Sandbox/fallback/Free
  # accounts would dead-end at the login endpoint, so the flag hides the CTA.
  describe "GET /api/profiles/public/:slug (sign_in_available flag)" do
    let(:owner) { FactoryBot.create(:user, plan_type: "pro") }

    def public_body_for(child)
      profile = Profile.create!(
        profileable: child,
        username: "sign-in-#{SecureRandom.hex(3)}",
        slug: "sign-in-#{SecureRandom.hex(3)}",
      )
      get "/api/profiles/public/#{profile.slug}"
      expect(response).to have_http_status(:ok)
      JSON.parse(response.body)
    end

    it "is true for an active communicator with a passcode" do
      child = FactoryBot.create(
        :child_account, user: owner, owner: owner,
        name: "Ada", status: "active", passcode: "letmein1"
      )

      expect(public_body_for(child)["sign_in_available"]).to be(true)
    end

    it "is false for a sandbox communicator" do
      child = FactoryBot.create(
        :child_account, user: owner, owner: owner,
        name: "Ada", status: "sandbox"
      )

      expect(public_body_for(child)["sign_in_available"]).to be(false)
    end

    it "is false for a communicator in fallback mode" do
      child = FactoryBot.create(
        :child_account, user: owner, owner: owner,
        name: "Ada", status: "active", passcode: "letmein1"
      )
      child.enter_fallback!

      expect(public_body_for(child.reload)["sign_in_available"]).to be(false)
    end

    it "never exposes the passcode alongside the flag" do
      child = FactoryBot.create(
        :child_account, user: owner, owner: owner,
        name: "Ada", status: "active", passcode: "letmein1"
      )
      body = public_body_for(child)

      expect(body["sign_in_available"]).to be(true)
      expect(body).not_to have_key("passcode")
      expect(response.body).not_to include("letmein1")
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

  # MySpeak page theme (issue #476): owner-picked theme round-trips through
  # PATCH /api/profiles/:id and surfaces on the public safety_view payload.
  describe "MySpeak page theme (settings.theme)" do
    let(:owner) { FactoryBot.create(:user) }
    let(:other_user) { FactoryBot.create(:user) }
    let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Sky") }
    let!(:profile) do
      Profile.new(profileable: child, username: "sky-theme", slug: "sky-theme").tap(&:save!)
    end

    before do
      # generate_attachments! shells out to Grover/puppeteer; not what these
      # specs exercise and unavailable on CI.
      allow_any_instance_of(Profile).to receive(:generate_attachments!).and_return(true)
    end

    it "persists a valid theme and returns it on api_view" do
      put "/api/profiles/#{profile.id}",
          params: { profile: { settings: { theme: { preset: "ocean", accent: "#0EA5E9", bg_color: "#F0F9FF" } } } },
          headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      theme = JSON.parse(response.body).dig("settings", "theme")
      expect(theme).to eq("preset" => "ocean", "accent" => "#0EA5E9", "bg_color" => "#F0F9FF")
      expect(profile.reload.settings["theme"]).to eq(theme)
    end

    it "drops invalid theme values on write" do
      put "/api/profiles/#{profile.id}",
          params: { profile: { settings: { theme: { accent: "red", preset: "javascript:alert(1)", bg_color: "#0EA5E9" } } } },
          headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(profile.reload.settings["theme"]).to eq("bg_color" => "#0EA5E9")
    end

    it "surfaces the theme on the public safety_view payload" do
      profile.update!(settings: { "theme" => { "preset" => "ocean", "accent" => "#0EA5E9" } })

      get "/api/profiles/public/#{profile.slug}"

      expect(response).to have_http_status(:ok)
      theme = JSON.parse(response.body).dig("settings", "theme")
      expect(theme).to eq("preset" => "ocean", "accent" => "#0EA5E9")
    end

    it "still withholds sensitive safety keys from the public payload" do
      profile.update!(settings: {
        "theme" => { "accent" => "#0EA5E9" },
        "allergies" => "peanuts",
        "ice_contact_1" => "Mom 555-1234",
      })

      get "/api/profiles/public/#{profile.slug}"

      body = JSON.parse(response.body)
      expect(body.dig("settings", "theme")).to eq("accent" => "#0EA5E9")
      expect(body["settings"]).not_to have_key("allergies")
      expect(body["settings"]).not_to have_key("ice_contact_1")
      expect(response.body).not_to include("peanuts")
    end

    it "forbids a non-owner from changing the theme" do
      put "/api/profiles/#{profile.id}",
          params: { profile: { settings: { theme: { accent: "#0EA5E9" } } } },
          headers: auth_headers(other_user)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("not_owner")
      expect(profile.reload.settings["theme"]).to be_nil
    end
  end

  # The MySpeak page is unauthenticated and is the page a printed QR code
  # lands on. Its board lists used to be serialized with the full editor
  # api_view, which both cost seconds per request and published identities
  # (Board#api_view -> in_use_by / communicator_account_data;
  # ChildBoard#api_view -> added_by, the assigning user's EMAIL).
  describe "GET /api/profiles/public/:slug board payload" do
    let(:owner) { FactoryBot.create(:user, email: "assigning-parent@example.com") }
    let(:admin_user) { User.find_by(id: User::DEFAULT_ADMIN_ID) || FactoryBot.create(:admin_user, id: User::DEFAULT_ADMIN_ID) }
    let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Sky Doe") }
    let!(:profile) do
      Profile.new(profileable: child, username: "sky-boards", slug: "sky-boards").tap(&:save!)
    end
    let!(:library_board) do
      FactoryBot.create(:board, user: admin_user, predefined: true, published: true, parent_type: "User")
    end
    let!(:favorite) do
      board = FactoryBot.create(:board, user: owner, name: "Snack Time")
      FactoryBot.create(:child_board, board: board, child_account: child, favorite: true, created_by: owner)
    end

    before do
      allow_any_instance_of(Profile).to receive(:generate_attachments!).and_return(true)
    end

    it "serves the communicator's boards as cards without the assigner's email" do
      get "/api/profiles/public/#{profile.slug}"

      expect(response).to have_http_status(:ok)
      card = JSON.parse(response.body)["public_boards"].first
      expect(card["name"]).to eq("Snack Time")
      expect(card["board_id"]).to eq(favorite.board_id)
      expect(card).not_to have_key("added_by")
      expect(card).not_to have_key("added_by_id")
      expect(card).not_to have_key("board_owner_name")
      expect(response.body).not_to include("assigning-parent@example.com")
    end

    # The MySpeak board grid resolves a thumbnail through
    # display_image_url -> preset_display_image_url -> preview_image_url. The
    # communicator card omitted the middle key, so a board whose only cover was
    # the legacy settings snapshot rendered as a "Board thumbnail" placeholder
    # while the same board in the library grid rendered fine.
    it "serves the communicator's cards with the cover fallback the library cards have" do
      favorite.board.update!(
        settings: favorite.board.settings.to_h.merge(
          "preset_display_image_url" => "https://cdn.example.com/snack-cover.png",
        ),
      )

      get "/api/profiles/public/#{profile.slug}"

      card = JSON.parse(response.body)["public_boards"].first
      expect(card["preset_display_image_url"]).to eq("https://cdn.example.com/snack-cover.png")
      expect(card.keys).to include(*JSON.parse(response.body)["general_public_boards"].first.keys)
    end

    it "serves the admin library as cards without communicator identities" do
      get "/api/profiles/public/#{profile.slug}"

      cards = JSON.parse(response.body)["general_public_boards"]
      expect(cards.map { |c| c["id"] }).to include(library_board.id)
      cards.each do |card|
        expect(card).not_to have_key("in_use_by")
        expect(card).not_to have_key("communicator_account_data")
      end
      # The page legitimately shows this communicator's own name; what must not
      # appear is any communicator name reachable through a library board card.
      expect(cards.to_json).not_to include("Sky Doe")
    end

    it "invalidates the ETag when a library board changes" do
      get "/api/profiles/public/#{profile.slug}"
      first_etag = response.headers["ETag"]
      expect(first_etag).to be_present

      library_board.touch

      get "/api/profiles/public/#{profile.slug}"
      expect(response.headers["ETag"]).not_to eq(first_etag)
    end

    # public_page_board_ids used to pluck the ChildBoard join row's own id and
    # hand it to Board.where(id:), so the favorited Board could never be found
    # and Last-Modified always collapsed to the profile's own timestamp.
    it "tracks the favorited board's updated_at in Last-Modified" do
      board_touched_at = 1.hour.from_now.change(usec: 0)
      profile.update_columns(updated_at: 3.days.ago)
      favorite.board.update_columns(updated_at: board_touched_at)

      get "/api/profiles/public/#{profile.slug}"

      expect(Time.parse(response.headers["Last-Modified"]))
        .to be_within(2.seconds).of(board_touched_at)
    end
  end

  # A User profile's public page (`/u/:slug`, profile_kind "public_page") lists
  # the user's OWN boards. That list was still going through Board#api_view,
  # so every visitor received `in_use_by` — the names of that user's own
  # communicators — plus communicator_account_data.
  describe "GET /api/profiles/public/:slug user_boards payload" do
    let(:owner) { FactoryBot.create(:user) }
    let!(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Rowan Doe") }
    let!(:profile) do
      Profile.new(profileable: owner, username: "pat-pages", slug: "pat-pages").tap(&:save!)
    end
    # board_type must be set: Board.main_boards filters through non_menus,
    # whose `where.not(board_type: "menu")` drops rows with a NULL board_type.
    let!(:board) do
      FactoryBot.create(:board, user: owner, name: "Morning Routine",
                        published: true, board_type: "board", sub_board: false)
    end

    before do
      allow_any_instance_of(Profile).to receive(:generate_attachments!).and_return(true)
      board.update!(in_use: true)
      FactoryBot.create(:child_board, board: board, child_account: child, created_by: owner)
    end

    it "serves the page as the public_page kind" do
      expect(profile.reload).to be_public_page
    end

    it "lists the user's boards with the fields the public grids render" do
      get "/api/profiles/public/#{profile.slug}"

      expect(response).to have_http_status(:ok)
      card = JSON.parse(response.body)["user_boards"].find { |b| b["id"] == board.id }
      expect(card).to be_present
      expect(card["name"]).to eq("Morning Routine")
      expect(card["slug"]).to eq(board.slug)
      expect(card["published"]).to be(true)
      expect(card["predefined"]).to be(false)
      expect(card["can_edit"]).to be(false)
    end

    it "does not publish the owner's communicator names" do
      get "/api/profiles/public/#{profile.slug}"

      cards = JSON.parse(response.body)["user_boards"]
      cards.each do |card|
        expect(card).not_to have_key("in_use_by")
        expect(card).not_to have_key("communicator_account_data")
      end
      expect(response.body).not_to include("Rowan Doe")
    end

    # `favorite_boards` differs in RETURN TYPE by profileable:
    # ChildAccount#favorite_boards -> ChildBoard join rows,
    # User#favorite_boards -> Boards. Preloading `board:` against the Board
    # relation raises AssociationNotFoundError and 500s the whole public page.
    context "when the user has favorited a board" do
      before { board.update!(favorite: true) }

      it "serves the page instead of raising on the preload" do
        get "/api/profiles/public/#{profile.slug}"

        expect(response).to have_http_status(:ok)
        cards = JSON.parse(response.body)["public_boards"]
        expect(cards.map { |c| c["id"] }).to include(board.id)
      end

      it "still serializes those boards as cards" do
        get "/api/profiles/public/#{profile.slug}"

        card = JSON.parse(response.body)["public_boards"].find { |c| c["id"] == board.id }
        expect(card["name"]).to eq("Morning Routine")
        expect(card).not_to have_key("in_use_by")
        expect(card).not_to have_key("communicator_account_data")
      end
    end
  end

  # The grid is selected on `child_boards.favorite`, but the board behind each
  # card is gated on Board#viewable_by?, which refuses an anonymous visitor an
  # unpublished board. An unfiltered grid therefore served a card (name, slug,
  # cover) for a private board and 404'd whoever tapped it.
  describe "GET /api/profiles/public/:slug (unpublished boards)" do
    let(:owner) { FactoryBot.create(:user) }
    let(:other_user) { FactoryBot.create(:user) }
    let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Sky Doe") }
    let!(:profile) do
      Profile.new(profileable: child, username: "sky-private", slug: "sky-private").tap(&:save!)
    end

    before do
      allow_any_instance_of(Profile).to receive(:generate_attachments!).and_return(true)
    end

    def public_board_ids
      JSON.parse(response.body)["public_boards"].map { |c| c["board_id"] }
    end

    it "publishes the owner's board on favorite so its card works" do
      board = FactoryBot.create(:board, user: owner, name: "Snack Time", published: false)
      FactoryBot.create(:child_board, board: board, child_account: child,
                                      favorite: true, created_by: owner)

      get "/api/profiles/public/#{profile.slug}"

      expect(board.reload.published).to be true
      expect(public_board_ids).to include(board.id)
    end

    # A board owned by someone else is deliberately not auto-published — a
    # parent's favorite tap is not that user's consent. The filter is what
    # keeps the invariant true for it.
    it "omits a favorited board owned by another user that is unpublished" do
      board = FactoryBot.create(:board, user: other_user, name: "SLP Board", published: false)
      FactoryBot.create(:child_board, board: board, child_account: child,
                                      favorite: true, created_by: owner)

      get "/api/profiles/public/#{profile.slug}"

      expect(response).to have_http_status(:ok)
      expect(board.reload.published).to be false
      expect(public_board_ids).not_to include(board.id)
      expect(response.body).not_to include("SLP Board")
    end

    # Legacy rows: favorited before the publish-on-favorite hook existed, or
    # unpublished afterwards from the board editor.
    it "omits a favorited board that was unpublished after the fact" do
      board = FactoryBot.create(:board, user: owner, name: "Retired Board", published: false)
      FactoryBot.create(:child_board, board: board, child_account: child,
                                      favorite: true, created_by: owner)
      board.reload.update!(published: false)

      get "/api/profiles/public/#{profile.slug}"

      expect(public_board_ids).not_to include(board.id)
      expect(response.body).not_to include("Retired Board")
    end
  end
end
