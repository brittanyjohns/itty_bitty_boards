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
      about_me: "Loves big hugs and dinosaurs. Ask me about my rock collection.",
      emergency_notes: "Has seizures. Use a calm voice when overwhelmed.",
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
        # Safety profiles get an unguessable random slug, not a name-derived one.
        expect(profile.slug).to match(/\As-[a-z0-9]{6}\z/)
        expect(profile.slug_type).to eq("random")
        # ...but the username stays readable (it's the handle, not the public URL).
        expect(profile.username).to eq("river-stone")
        # About Me → public bio; emergency notes → private (gated) settings.
        expect(profile.bio).to include("Loves big hugs")
        expect(profile.settings["emergency_notes"]).to include("Has seizures")
        expect(profile.avatar).to be_attached
        expect(profile.settings["pronouns"]).to eq("they/them")
        expect(profile.settings["ice_contact_1"]).to eq(
          "name" => "Sam Stone", "relationship" => "Parent", "phone" => "555-0101",
        )
        expect(profile.settings["ice_contact_2"]["name"]).to eq("Kit Stone")
        expect(profile.settings["ice_contact_3"]["name"]).to eq("Jo Stone")

        body = JSON.parse(response.body)
        expect(body["slug"]).to match(/\As-[a-z0-9]{6}\z/)
        expect(body["profile_kind"]).to eq("safety")
        expect(body["settings"]["pronouns"]).to eq("they/them")
        expect(body["settings"]["ice_contact_1"]["phone"]).to eq("555-0101")
      end
    end

    context "About Me vs emergency notes split" do
      it "routes about_me to the public bio and emergency_notes to the gated settings" do
        post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers

        expect(response).to have_http_status(:created)
        profile = user.communicator_accounts.last.profile
        # Public About Me = bio; withheld from the open page's settings.
        expect(profile.bio).to include("dinosaurs")
        expect(profile.public_settings(kind: :safety)).not_to include("emergency_notes")
        # Private emergency notes live behind the gated reveal.
        expect(profile.settings["emergency_notes"]).to include("Has seizures")
        expect(profile.has_safety_info?).to be(true)
        expect(profile.safety_sensitive_settings["emergency_notes"]).to include("Has seizures")
      end

      it "leaves the public bio blank when only emergency_notes is provided" do
        payload = base_payload.except(:about_me)
        post "/api/v1/onboarding/myspeak", params: payload.to_json, headers: headers

        expect(response).to have_http_status(:created)
        profile = user.communicator_accounts.last.profile
        # No About Me typed → the public bio stays empty. The safety text must
        # not leak into it, and it is no longer seeded with instructional copy
        # either — the MySpeak page used to publish that as the owner's own
        # About Me.
        expect(profile.bio).to be_blank
        expect(profile.settings["emergency_notes"]).to include("Has seizures")
      end

      it "does not populate emergency_notes when only about_me is provided" do
        payload = base_payload.except(:emergency_notes)
        post "/api/v1/onboarding/myspeak", params: payload.to_json, headers: headers

        expect(response).to have_http_status(:created)
        profile = user.communicator_accounts.last.profile
        expect(profile.bio).to include("dinosaurs")
        expect(profile.settings["emergency_notes"]).to be_nil
      end

      context "legacy client (care_notes only)" do
        it "routes care_notes to the PRIVATE emergency notes, never the public bio" do
          payload = base_payload.except(:about_me, :emergency_notes)
                                .merge(care_notes: "Allergic to peanuts. Calming phrase: 'you are safe.'")
          post "/api/v1/onboarding/myspeak", params: payload.to_json, headers: headers

          expect(response).to have_http_status(:created)
          profile = user.communicator_accounts.last.profile
          # Old framing was safety info — privacy wins: it must NOT be public bio.
          expect(profile.bio).not_to include("peanuts")
          expect(profile.bio).to be_blank
          expect(profile.settings["emergency_notes"]).to include("peanuts")
        end
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
        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["details"]).to include(/Name/)
      end
    end

    context "username collision" do
      it "appends -2 to the username while the slug stays random" do
        Profile.create!(
          username: "river-stone",
          slug: "river-stone",
          bio: "x",
          intro: "y",
        )

        post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers

        expect(response).to have_http_status(:created)
        new_profile = user.communicator_accounts.last.profile
        expect(new_profile.username).to eq("river-stone-2")
        expect(new_profile.slug).to match(/\As-[a-z0-9]{6}\z/)
      end
    end

    context "random safety slug (the wizard no longer collects a link)" do
      it "assigns a random slug and ignores any client-supplied slug" do
        post "/api/v1/onboarding/myspeak",
             params: base_payload.merge(slug: "my-custom-link").to_json, headers: headers

        expect(response).to have_http_status(:created)
        profile = user.communicator_accounts.last.profile
        expect(profile.slug).to match(/\As-[a-z0-9]{6}\z/)
        expect(profile.slug).not_to eq("my-custom-link")
        expect(profile.username).to eq("river-stone")
      end

      it "assigns a random slug even when no slug param is sent" do
        post "/api/v1/onboarding/myspeak",
             params: base_payload.to_json, headers: headers

        expect(response).to have_http_status(:created)
        profile = user.communicator_accounts.last.profile
        expect(profile.slug).to match(/\As-[a-z0-9]{6}\z/)
        expect(profile.slug_type).to eq("random")
      end

      it "does not 422 on a client slug that would otherwise be reserved/taken" do
        # The slug is ignored entirely now, so a 'reserved' value can't error.
        post "/api/v1/onboarding/myspeak",
             params: base_payload.merge(slug: "admin").to_json, headers: headers

        expect(response).to have_http_status(:created)
        expect(user.communicator_accounts.last.profile.slug).to match(/\As-[a-z0-9]{6}\z/)
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

    # Regression for the #761 follow-up. #761 stopped the auto-minted Profile
    # being double-counted, but left the wizard with only one move — create a
    # NEW communicator. A Free user gets exactly one self-create, and adding a
    # communicator from the dashboard spends it, so the user whose page already
    # existed (blank) stayed refused at the final step. The wizard now sets up
    # THAT page instead of demanding a slot she can never have.
    context "free user has no available communicator slot" do
      # A Free MySpeak account is a no-login sandbox, so the binding limit is
      # the sandbox slot (demo_communicator_limit = 1). Take it.
      def take_the_slot!(username: "existing-kid", name: "Existing Kid")
        FactoryBot.create(
          :child_account,
          user: user,
          owner: user,
          name: name,
          username: username,
          status: ChildAccount::SANDBOX,
        )
      end

      # Mirrors ChildAccount#create_profile! — the page every communicator gets
      # for free when it's added from the dashboard. Note the NAME-DERIVED slug:
      # create_profile! passes `slug:` explicitly, so Profile#ensure_slug (and
      # its random-slug rule) never runs.
      def mint_blank_page!(child)
        Profile.create!(
          profileable: child,
          username: child.username,
          slug: child.username.parameterize,
        )
      end

      context "when the existing communicator's page was never set up" do
        it "adopts that page instead of creating a second communicator" do
          child = take_the_slot!
          blank = mint_blank_page!(child)

          expect {
            post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers
          }.to not_change { user.communicator_accounts.count }
           .and not_change { Profile.count }

          expect(response).to have_http_status(:created)
          body = JSON.parse(response.body)
          expect(body["adopted"]).to be(true)

          blank.reload
          expect(blank.profileable_id).to eq(child.id)
          expect(blank.profile_kind).to eq("safety")
          expect(blank.bio).to eq(base_payload[:about_me])
          expect(blank.settings["pronouns"]).to eq("they/them")
          expect(blank.settings["emergency_notes"]).to eq(base_payload[:emergency_notes])
          expect(blank.settings["ice_contact_1"]).to include("name" => "Sam Stone")
        end

        it "re-slugs the adopted page so a child's emergency page stays unguessable" do
          child = take_the_slot!(username: "river-stone")
          blank = mint_blank_page!(child)
          expect(blank.slug).to eq("river-stone")

          post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers

          expect(response).to have_http_status(:created)
          expect(blank.reload.slug).to match(/\As-[a-z0-9]{6}\z/)
          expect(blank.slug_type).to eq("random")
        end

        it "renames the communicator to the name typed in the wizard, leaving the username alone" do
          child = take_the_slot!(username: "existing-kid", name: "Existing Kid")
          mint_blank_page!(child)

          post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers

          expect(response).to have_http_status(:created)
          child.reload
          # safety_view reads its name from profileable.name, so without the
          # rename the name the parent just typed vanishes from her own page.
          expect(child.name).to eq("River Stone")
          # The handle backs a private sign-in on an active communicator.
          expect(child.username).to eq("existing-kid")
        end

        it "reports an adopt as an adopt, never as a communicator create" do
          allow(PosthogService).to receive(:capture_for_user)
          child = take_the_slot!
          mint_blank_page!(child)

          post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers

          expect(PosthogService).to have_received(:capture_for_user)
            .with(user, "myspeak_page_adopted", hash_including(:properties))
          expect(PosthogService).not_to have_received(:capture_for_user)
            .with(user, "communicator_account_created", anything)
          expect(PosthogService).not_to have_received(:capture_for_user)
            .with(user, "myspeak_page_created", anything)
        end
      end

      context "when the existing communicator has no page at all" do
        it "creates the page on that communicator rather than a new one" do
          child = take_the_slot!

          expect {
            post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers
          }.to change { Profile.count }.by(1)
           .and not_change { user.communicator_accounts.count }

          expect(response).to have_http_status(:created)
          expect(child.reload.profile).to be_present
          expect(child.profile.slug).to match(/\As-[a-z0-9]{6}\z/)
        end
      end

      context "when the existing communicator's page is already set up" do
        it "returns 422 communicator_slot_unavailable and never overwrites it" do
          child = take_the_slot!
          page = Profile.create!(
            profileable: child,
            username: child.username,
            slug: child.username.parameterize,
            bio: "Ada loves trains and knows every station on the line.",
            settings: { "ice_contact_1" => { "name" => "Ada's mum", "phone" => "555-9000" } },
          )

          post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers

          expect(response).to have_http_status(:unprocessable_content)
          body = JSON.parse(response.body)
          expect(body["error"]).to eq("communicator_slot_unavailable")

          page.reload
          expect(page.bio).to eq("Ada loves trains and knows every station on the line.")
          expect(page.settings["ice_contact_1"]).to include("name" => "Ada's mum")
        end
      end

      context "when several communicators have a blank page" do
        # A Pro user downgraded to Free keeps the communicators; only the cap
        # moved. Picking one for her would write one child's emergency contacts
        # onto another child's page, so the wizard asks.
        let!(:first)  { take_the_slot!(username: "kid-one", name: "Kid One") }
        let!(:second) { take_the_slot!(username: "kid-two", name: "Kid Two") }

        before do
          mint_blank_page!(first)
          mint_blank_page!(second)
        end

        it "refuses to guess and returns the candidates" do
          post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers

          expect(response).to have_http_status(:unprocessable_content)
          body = JSON.parse(response.body)
          expect(body["error"]).to eq("communicator_selection_required")
          expect(body["communicators"].map { |c| c["id"] }).to contain_exactly(first.id, second.id)
        end

        it "adopts the one named by communicator_id" do
          payload = base_payload.merge(communicator_id: second.id)

          post "/api/v1/onboarding/myspeak", params: payload.to_json, headers: headers

          expect(response).to have_http_status(:created)
          expect(second.reload.profile.settings["emergency_notes"])
            .to eq(base_payload[:emergency_notes])
          expect(first.reload.profile.settings["emergency_notes"]).to be_blank
        end
      end
    end

    # Regression for #761. The user-level Public page and a communicator's
    # MySpeak page are different products; they used to share one counter, so
    # owning a Public page refused a MySpeak page our copy promises is free on
    # every plan. The communicator SLOT (covered above) is the only quota here.
    context "free user who already has their own Public page" do
      it "can still create a communicator MySpeak page" do
        Profile.create!(
          profileable: user,
          username: "first-#{SecureRandom.hex(2)}",
          slug: "first-#{SecureRandom.hex(2)}",
        )

        post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers

        expect(response).to have_http_status(:created)
        expect(user.communicator_accounts.last.profile).to be_present
      end
    end
  end
end
