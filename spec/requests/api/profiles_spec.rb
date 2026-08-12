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
end
