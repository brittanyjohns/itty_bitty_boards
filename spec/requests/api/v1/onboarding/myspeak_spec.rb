require "rails_helper"

RSpec.describe "API::V1::Onboarding::Myspeak", type: :request do
  # 1x1 transparent PNG
  PNG_DATA_URL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=".freeze

  let(:user) do
    u = FactoryBot.create(:user)
    # Pull out of the soft-trial window so paid_plan? is false and we can test
    # the genuine Free state.
    u.update_columns(plan_type: "free", created_at: 60.days.ago)
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
      it "creates a child account + safety profile, attaches avatar, writes settings" do
        expect {
          post "/api/v1/onboarding/myspeak", params: base_payload.to_json, headers: headers
        }.to change { user.communicator_accounts.count }.by(1)
         .and change { Profile.count }.by(1)

        expect(response).to have_http_status(:created)

        child = user.communicator_accounts.order(:created_at).last
        expect(child.name).to eq("River Stone")
        expect(child.username).to eq("river-stone")

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

    context "board_id 'later'" do
      it "does not create a ChildBoard" do
        expect {
          post "/api/v1/onboarding/myspeak",
               params: base_payload.merge(board_id: "later").to_json, headers: headers
        }.not_to change { ChildBoard.count }
        expect(response).to have_http_status(:created)
      end
    end

    context "board_id matches a seeded starter board" do
      it "favorites it on the new communicator" do
        admin = FactoryBot.create(:admin_user)
        starter = Board.create!(
          slug: "myspeak-basics",
          name: "Basic needs",
          user: admin,
          parent: admin,
          predefined: true,
          published: true,
          board_type: "board",
        )

        post "/api/v1/onboarding/myspeak",
             params: base_payload.merge(board_id: "basics").to_json, headers: headers

        expect(response).to have_http_status(:created)
        child = user.communicator_accounts.last
        cb = child.child_boards.find_by(board: starter)
        expect(cb).to be_present
        expect(cb.favorite).to eq(true)
        expect(cb.created_by_id).to eq(user.id)
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
