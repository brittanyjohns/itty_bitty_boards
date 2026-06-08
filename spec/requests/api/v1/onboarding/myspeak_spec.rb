require "rails_helper"

RSpec.describe "API::V1::Onboarding::Myspeak", type: :request do
  # 1x1 transparent PNG
  PNG_DATA_URL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=".freeze

  let(:user) do
    u = FactoryBot.create(:user)
    # Pull out of the soft-trial window so paid_plan? is false. The factory
    # user gets seeded with Basic-tier limits via the soft-trial callback;
    # overwrite the slot limits to match production Free state
    # (paid_communicator_limit = 1, demo_communicator_limit = 1).
    free_settings = u.settings.merge(
      "paid_communicator_limit" => 1,
      "demo_communicator_limit" => 1,
      "board_limit" => 1,
    )
    u.update_columns(plan_type: "free", created_at: 60.days.ago, settings: free_settings)
    u
  end

  let(:headers) { auth_headers(user).merge("Content-Type" => "application/json") }

  let(:base_payload) do
    {
      name: "River Stone",
      pronouns: "they/them",
      photo_data_url: PNG_DATA_URL,
      board_id: "later",
      care_notes: "Loves big hugs. Use a calm voice when overwhelmed.",
      contacts: [
        { name: "Sam Stone", relationship: "Parent", phone: "555-0101" },
        { name: "Kit Stone", relationship: "Aunt",   phone: "555-0102" },
        { name: "Jo Stone",  relationship: "Friend", phone: "555-0103" },
      ],
    }
  end

  before do
    # The synchronous PDF/PNG generation in Profile#generate_attachments! is
    # heavy (Grover-style HTML rendering) and not what these specs are about.
    allow_any_instance_of(Profile).to receive(:generate_attachments!).and_return(true)
  end

  describe "POST /api/v1/onboarding/myspeak" do
    context "without auth" do
      it "returns 401" do
        post "/api/v1/onboarding/myspeak", params: base_payload.to_json,
             headers: { "Content-Type" => "application/json" }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "happy path" do
      it "creates a no-login sandbox (MySpeak Free) child account + safety profile, attaches avatar, writes settings, sets up a team" do
        expect {
          post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers
        }.to change { user.communicator_accounts.count }.by(1)
         .and change { Profile.count }.by(1)

        expect(response).to have_http_status(:created)

        child = user.communicator_accounts.order(:created_at).last
        expect(child.name).to eq("River Stone")
        expect(child.username).to eq("river-stone")
        # A Free user's self-created MySpeak account is a no-login sandbox —
        # full login only ever arrives via claim/hand-off.
        expect(child.status).to eq(ChildAccount::SANDBOX)

        team = child.teams.first
        expect(team).to be_present
        expect(team.name).to eq("River Stone's Communication Team")
        expect(team.team_users.where(user: user, role: "admin")).to exist

        profile = child.profile
        expect(profile.profile_kind).to eq("safety")
        expect(profile.slug).to eq("river-stone")
        expect(profile.username).to eq("river-stone")
        expect(profile.bio).to include("Loves big hugs")
        expect(profile.avatar).to be_attached
        expect(profile.settings["pronouns"]).to eq("they/them")
        expect(profile.settings["ice_contact_1"]).to eq(
          "name" => "Sam Stone", "relationship" => "Parent", "phone" => "555-0101",
        )
        expect(profile.settings["ice_contact_2"]["name"]).to eq("Kit Stone")
        expect(profile.settings["ice_contact_3"]["name"]).to eq("Jo Stone")

        body = JSON.parse(response.body)
        expect(body["slug"]).to eq("river-stone")
        expect(body["profile_kind"]).to eq("safety")
        expect(body["settings"]["pronouns"]).to eq("they/them")
        expect(body["settings"]["ice_contact_1"]["phone"]).to eq("555-0101")
      end
    end

    context "paid user" do
      let(:user) do
        u = FactoryBot.create(:user)
        u.update_columns(plan_type: "pro", created_at: 60.days.ago)
        u
      end

      it "creates a full (active) communicator — only Free self-creates are sandboxed" do
        post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers

        expect(response).to have_http_status(:created)
        child = user.communicator_accounts.order(:created_at).last
        expect(child.status).to eq(ChildAccount::ACTIVE)
      end
    end

    context "missing name" do
      it "returns 422" do
        post "/api/v1/onboarding/myspeak",
             params: base_payload.merge(name: "").to_json, headers: headers
        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["details"]).to include(/Name/)
      end
    end

    context "slug collision" do
      it "appends -2 to the slug" do
        Profile.create!(
          username: "river-stone",
          slug: "river-stone",
          bio: "x",
          intro: "y",
        )

        post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers

        expect(response).to have_http_status(:created)
        new_profile = user.communicator_accounts.last.profile
        expect(new_profile.slug).to eq("river-stone-2")
        expect(new_profile.username).to eq("river-stone-2")
      end
    end

    context "user-picked slug from the 'Pick your link' wizard step" do
      it "uses the picked slug when it's available and well-formed" do
        post "/api/v1/onboarding/myspeak",
             params: base_payload.merge(slug: "my-custom-link").to_json, headers: headers

        expect(response).to have_http_status(:created)
        profile = user.communicator_accounts.last.profile
        expect(profile.slug).to eq("my-custom-link")
        expect(profile.username).to eq("my-custom-link")
      end

      it "rejects a picked slug with bad format (422 slug_invalid)" do
        post "/api/v1/onboarding/myspeak",
             params: base_payload.merge(slug: "Bad_Slug!").to_json, headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to eq("slug_invalid")
      end

      it "rejects a reserved slug (422 slug_reserved)" do
        post "/api/v1/onboarding/myspeak",
             params: base_payload.merge(slug: "admin").to_json, headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to eq("slug_reserved")
      end

      it "rejects a taken slug (422 slug_taken)" do
        Profile.create!(username: "river-stone", slug: "river-stone", bio: "x", intro: "y")

        post "/api/v1/onboarding/myspeak",
             params: base_payload.merge(slug: "river-stone").to_json, headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to eq("slug_taken")
      end

      it "falls back to auto-generated slug when slug param is blank" do
        post "/api/v1/onboarding/myspeak",
             params: base_payload.merge(slug: "").to_json, headers: headers

        expect(response).to have_http_status(:created)
        profile = user.communicator_accounts.last.profile
        expect(profile.slug).to eq("river-stone")
      end
    end

    context "board_id 'later'" do
      it "does not create a ChildBoard" do
        expect {
          post "/api/v1/onboarding/myspeak",
               params: base_payload.merge(board_id: "later").to_json, headers: headers
        }.not_to change { ChildBoard.count }
        expect(response).to have_http_status(:created)
      end
    end

    context "board_id matches a public starter board" do
      let(:admin) do
        a = FactoryBot.create(:admin_user)
        # Board.public_boards is anchored on User::DEFAULT_ADMIN_ID, so
        # force the admin factory's row to that id rather than depending on
        # the test db being clean.
        a.update_columns(id: User::DEFAULT_ADMIN_ID) unless a.id == User::DEFAULT_ADMIN_ID
        a
      end

      let(:starter) do
        Board.create!(
          name: "Basic needs",
          user_id: User::DEFAULT_ADMIN_ID,
          parent: admin,
          predefined: true,
          published: true,
          board_type: "board",
        )
      end

      it "clones the public board, attaches the clone as a favorited ChildBoard, and assigns ownership to current_user" do
        starter # force creation

        expect {
          post "/api/v1/onboarding/myspeak",
               params: base_payload.merge(board_id: starter.id).to_json, headers: headers
        }.to change { Board.count }.by(1)
         .and change { ChildBoard.count }.by(1)

        expect(response).to have_http_status(:created)

        child = user.communicator_accounts.last
        cb = child.child_boards.last
        expect(cb.favorite).to eq(true)
        # The attached board is the *clone*, not the master.
        expect(cb.board_id).not_to eq(starter.id)
        expect(cb.board.user_id).to eq(user.id)
        expect(cb.board.name).to eq(starter.name)
        # Master untouched.
        expect(starter.reload.user_id).to eq(User::DEFAULT_ADMIN_ID)
      end

      it "accepts board_id as a string (JSON normally sends integers, but be defensive)" do
        starter

        post "/api/v1/onboarding/myspeak",
             params: base_payload.merge(board_id: starter.id.to_s).to_json, headers: headers

        expect(response).to have_http_status(:created)
        child = user.communicator_accounts.last
        expect(child.child_boards.count).to eq(1)
      end

      it "silently skips when board_id references a board outside the public picker" do
        private_board = Board.create!(
          name: "Private board",
          user: user, # not admin → not in Board.public_boards
          parent: user,
          predefined: false,
          published: false,
          board_type: "board",
        )

        expect {
          post "/api/v1/onboarding/myspeak",
               params: base_payload.merge(board_id: private_board.id).to_json, headers: headers
        }.not_to change { ChildBoard.count }

        expect(response).to have_http_status(:created)
      end

      it "silently skips when board_id is unknown" do
        expect {
          post "/api/v1/onboarding/myspeak",
               params: base_payload.merge(board_id: 999_999).to_json, headers: headers
        }.not_to change { ChildBoard.count }

        expect(response).to have_http_status(:created)
      end

      it "silently skips when board_id is nil" do
        expect {
          post "/api/v1/onboarding/myspeak",
               params: base_payload.merge(board_id: nil).to_json, headers: headers
        }.not_to change { ChildBoard.count }

        expect(response).to have_http_status(:created)
      end
    end

    context "blank contacts are filtered" do
      it "only persists non-empty contacts and numbers them sequentially" do
        payload = base_payload.merge(contacts: [
          { name: "Sam", relationship: "Parent", phone: "555-1" },
          { name: "",    relationship: "",       phone: "" },
          { name: "Kit", relationship: "Aunt",   phone: "555-2" },
        ])
        post "/api/v1/onboarding/myspeak", params: payload.to_json, headers: headers

        expect(response).to have_http_status(:created)
        s = user.communicator_accounts.last.profile.settings
        expect(s["ice_contact_1"]["name"]).to eq("Sam")
        expect(s["ice_contact_2"]["name"]).to eq("Kit")
        expect(s["ice_contact_3"]).to be_nil
      end
    end

    context "photo_data_url is blank" do
      it "falls back to set_fake_avatar and still runs generate_attachments!" do
        # Stub the network call to ui-avatars.com; attach a tiny fixture
        # so profile.avatar is genuinely attached.
        png_bytes = Base64.strict_decode64(PNG_DATA_URL.split(",", 2).last)
        allow_any_instance_of(Profile).to receive(:set_fake_avatar) do |profile|
          profile.avatar.attach(
            io: StringIO.new(png_bytes),
            filename: "#{profile.slug}.png",
            content_type: "image/png",
          )
        end

        expect_any_instance_of(Profile).to receive(:set_fake_avatar).and_call_original
        expect_any_instance_of(Profile).to receive(:generate_attachments!).and_return(true)

        post "/api/v1/onboarding/myspeak",
             params: base_payload.merge(photo_data_url: "").to_json, headers: headers

        expect(response).to have_http_status(:created)
        profile = user.communicator_accounts.last.profile
        expect(profile.avatar).to be_attached
      end

      it "does not overwrite an uploaded avatar with the fallback" do
        expect_any_instance_of(Profile).not_to receive(:set_fake_avatar)

        post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers

        expect(response).to have_http_status(:created)
        expect(user.communicator_accounts.last.profile.avatar).to be_attached
      end
    end

    context "free user has no available communicator slot" do
      it "returns 422 communicator_slot_unavailable" do
        # A Free MySpeak account is a no-login sandbox, so the binding limit is
        # the sandbox slot (demo_communicator_limit = 1). Take it.
        FactoryBot.create(
          :child_account,
          user: user,
          owner: user,
          status: ChildAccount::SANDBOX,
        )

        post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("communicator_slot_unavailable")
      end
    end

    context "free user already at the MySpeak ID limit" do
      it "returns 403 myspeak_id_limit_reached" do
        Profile.create!(
          profileable: user,
          username: "first-#{SecureRandom.hex(2)}",
          slug: "first-#{SecureRandom.hex(2)}",
        )

        post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers

        expect(response).to have_http_status(:forbidden)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("myspeak_id_limit_reached")
        expect(body["limit"]).to eq(1)
      end
    end
  end
end
