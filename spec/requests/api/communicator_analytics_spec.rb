# frozen_string_literal: true

require "rails_helper"

# Server-side PostHog coverage for the communicator + page funnel (#766).
#
# The point of every example here is that the capture happens WITHOUT the
# frontend: the user who hits a limit is often the one who never accepted the
# cookie banner, so the JS SDK produces nothing at all for them.
RSpec.describe "Communicator + MySpeak analytics", type: :request do
  let(:user) do
    u = create(:user, created_at: 2.months.ago)
    u.setup_free_limits
    u.save!
    u
  end

  before do
    allow(PosthogService).to receive(:capture_for_user)
    # Grover-style attachment rendering isn't what these specs are about.
    allow_any_instance_of(Profile).to receive(:generate_attachments!).and_return(true)
  end

  describe "POST /api/child_accounts" do
    let(:params) do
      {
        name: "My Kid",
        username: "my-kid-#{SecureRandom.hex(3)}",
        status: "sandbox",
        password: "abcdef",
        password_confirmation: "abcdef",
      }
    end

    it "captures communicator_account_created and myspeak_page_created on success" do
      post "/api/child_accounts", params: params, headers: auth_headers(user)
      expect(response).to have_http_status(:created)

      child = ChildAccount.find_by(owner_id: user.id, status: "sandbox")

      expect(PosthogService).to have_received(:capture_for_user).with(
        user,
        "communicator_account_created",
        properties: hash_including(
          status: ChildAccount::SANDBOX,
          communicator_id: child.id,
          source: "child_accounts",
        ),
      )
      expect(PosthogService).to have_received(:capture_for_user).with(
        user,
        "myspeak_page_created",
        properties: hash_including(
          profile_id: child.profile.id,
          communicator_id: child.id,
          source: "child_accounts",
        ),
      )
    end

    it "captures communicator_slot_limit_reached when the slot is already taken" do
      create(:child_account, user: user, owner: user, status: "sandbox")

      post "/api/child_accounts", params: params, headers: auth_headers(user)
      expect(response).to have_http_status(:unprocessable_content)

      expect(PosthogService).to have_received(:capture_for_user).with(
        user,
        "communicator_slot_limit_reached",
        properties: hash_including(
          status: ChildAccount::SANDBOX,
          count: 1,
          source: "child_accounts",
        ),
      )
      expect(PosthogService).not_to have_received(:capture_for_user).with(
        user, "communicator_account_created", any_args
      )
    end

    it "does not report a MySpeak page when an existing profile is linked instead of minted" do
      profile = Profile.create!(
        profileable: nil,
        username: "handed-#{SecureRandom.hex(3)}",
        slug: "handed-#{SecureRandom.hex(3)}",
        placeholder: true,
        claim_token: SecureRandom.hex(8),
      )

      post "/api/child_accounts",
           params: params.merge(profile_id: profile.id),
           headers: auth_headers(user)
      expect(response).to have_http_status(:created)

      expect(PosthogService).not_to have_received(:capture_for_user).with(
        user, "myspeak_page_created", any_args
      )
    end
  end

  describe "POST /api/v1/onboarding/myspeak" do
    let(:payload) { { name: "River Stone", board_id: "later" } }
    let(:headers) { auth_headers(user).merge("Content-Type" => "application/json") }

    it "captures both creation events for the wizard route (the old coverage gap)" do
      post "/api/v1/onboarding/myspeak", params: payload.to_json, headers: headers
      expect(response).to have_http_status(:created)

      child = user.communicator_accounts.last

      expect(PosthogService).to have_received(:capture_for_user).with(
        user,
        "communicator_account_created",
        properties: hash_including(communicator_id: child.id, source: "myspeak_onboarding"),
      )
      expect(PosthogService).to have_received(:capture_for_user).with(
        user,
        "myspeak_page_created",
        properties: hash_including(profile_id: child.profile.id, source: "myspeak_onboarding"),
      )
    end

    it "captures the slot refusal at the end of the wizard" do
      # Out of slots is only a refusal when there is nothing to adopt, so the
      # existing communicator needs a page someone actually set up — a blank
      # one would be adopted instead.
      child = create(:child_account, user: user, owner: user,
                                     username: "taken-kid", status: ChildAccount::SANDBOX)
      Profile.create!(
        profileable: child,
        username: child.username,
        slug: child.username,
        settings: { "ice_contact_1" => { "name" => "Mum", "phone" => "555-0100" } },
      )

      post "/api/v1/onboarding/myspeak", params: payload.to_json, headers: headers
      expect(response).to have_http_status(:unprocessable_content)

      expect(PosthogService).to have_received(:capture_for_user).with(
        user,
        "communicator_slot_limit_reached",
        properties: hash_including(status: ChildAccount::SANDBOX, source: "myspeak_onboarding"),
      )
    end

    it "captures an adopt as an adopt when the wizard fills in a blank page instead" do
      child = create(:child_account, user: user, owner: user,
                                     username: "blank-kid", status: ChildAccount::SANDBOX)
      blank = Profile.create!(profileable: child, username: child.username, slug: child.username)

      post "/api/v1/onboarding/myspeak", params: payload.to_json, headers: headers
      expect(response).to have_http_status(:created)

      expect(PosthogService).to have_received(:capture_for_user).with(
        user,
        "myspeak_page_adopted",
        properties: hash_including(profile_id: blank.id, communicator_id: child.id,
                                   source: "myspeak_onboarding"),
      )
      # No account was created, so neither create event may fire.
      expect(PosthogService).not_to have_received(:capture_for_user)
        .with(user, "communicator_account_created", anything)
      expect(PosthogService).not_to have_received(:capture_for_user)
        .with(user, "myspeak_page_created", anything)
      expect(PosthogService).not_to have_received(:capture_for_user)
        .with(user, "communicator_slot_limit_reached", anything)
    end
  end

  describe "POST /api/profiles" do
    it "captures public_page_created on success" do
      post "/api/profiles",
           params: { profile: { username: "pub-#{SecureRandom.hex(3)}" } },
           headers: auth_headers(user)
      expect(response).to have_http_status(:created)

      expect(PosthogService).to have_received(:capture_for_user).with(
        user,
        "public_page_created",
        properties: hash_including(profile_id: user.reload.profile.id),
      )
    end

    it "captures public_page_create_blocked on the 409" do
      Profile.create!(profileable: user, username: "existing-#{SecureRandom.hex(3)}",
                      slug: "existing-#{SecureRandom.hex(3)}")

      post "/api/profiles",
           params: { profile: { username: "second-#{SecureRandom.hex(3)}" } },
           headers: auth_headers(user)
      expect(response).to have_http_status(:conflict)

      expect(PosthogService).to have_received(:capture_for_user).with(
        user,
        "public_page_create_blocked",
        properties: { reason: "public_page_exists" },
      )
    end
  end
end
