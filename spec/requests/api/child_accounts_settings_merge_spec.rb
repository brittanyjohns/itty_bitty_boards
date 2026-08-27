require "rails_helper"

# The communicator screen saves `settings` from several places — the Settings
# tab, the Boards-tab layout editor, the vendor form — and each builds a fresh
# literal holding only its own keys. Update therefore MERGES the incoming blob
# over what's stored; a wholesale assignment silently dropped everything the
# saving tab didn't know about.
RSpec.describe "API::ChildAccounts settings merge", type: :request do
  let(:user) { create(:user) }
  let(:communicator) { create(:child_account, user: user) }
  let(:headers) { auth_headers(user).merge("Content-Type" => "application/json") }

  def update_settings(settings, extra = {})
    patch "/api/child_accounts/#{communicator.id}",
          params: { settings: settings }.merge(extra).to_json,
          headers: headers
  end

  describe "PATCH /api/child_accounts/:id" do
    it "preserves keys the caller didn't send" do
      communicator.update!(settings: {
        "large_layout_cols" => 4,
        "primary_team_id" => 99,
        "enable_image_display" => true,
      })

      update_settings({ enable_image_display: false })

      expect(response).to have_http_status(:ok)
      settings = communicator.reload.settings
      expect(settings["enable_image_display"]).to be(false)
      expect(settings["large_layout_cols"]).to eq(4)
      expect(settings["primary_team_id"]).to eq(99)
    end

    it "still overwrites the keys the caller does send" do
      communicator.update!(settings: { "large_layout_cols" => 12 })

      update_settings({ large_layout_cols: 6 })

      expect(communicator.reload.settings["large_layout_cols"]).to eq(6)
    end

    # Clearing by omission is gone; clearing by explicit blank must still work,
    # because that is what every frontend form actually sends.
    it "clears a key sent as an explicit blank" do
      communicator.update!(settings: { "phrase_board_id" => "42" })

      update_settings({ phrase_board_id: "" })

      expect(communicator.reload.settings["phrase_board_id"]).to eq("")
    end

    it "clears a key sent as an explicit nil" do
      communicator.update!(settings: { "phrase_board_id" => "42" })

      update_settings({ phrase_board_id: nil })

      expect(communicator.reload.settings["phrase_board_id"]).to be_nil
    end

    it "replaces a nested hash wholesale rather than merging into it" do
      communicator.update!(settings: {
        "voice" => { "name" => "polly:kevin", "language" => "en-US" },
      })

      update_settings({ voice: { name: "", language: "en-US" } })

      expect(communicator.reload.settings["voice"]).to eq(
        "name" => "", "language" => "en-US",
      )
    end

    it "survives an account whose settings column is nil" do
      communicator.update_column(:settings, nil)

      update_settings({ enable_image_display: true })

      expect(response).to have_http_status(:ok)
      expect(communicator.reload.settings["enable_image_display"]).to be(true)
    end

    # The blob is unwhitelisted by design, but a string "false" is truthy in
    # Ruby — the flags the app branches on have to be stored as real booleans.
    it "casts string booleans on the display flags" do
      update_settings({ enable_image_display: "false", enable_text_display: "true" })

      settings = communicator.reload.settings
      expect(settings["enable_image_display"]).to be(false)
      expect(settings["enable_text_display"]).to be(true)
    end

    it "restores the model default for a display flag sent as nil" do
      communicator.update!(settings: { "enable_image_display" => false })

      update_settings({ enable_image_display: nil })

      expect(communicator.reload.settings["enable_image_display"]).to be(true)
    end

    it "leaves settings alone when the param is absent" do
      communicator.update!(settings: { "large_layout_cols" => 5 })

      patch "/api/child_accounts/#{communicator.id}",
            params: { name: "Renamed" }.to_json,
            headers: headers

      expect(communicator.reload.settings["large_layout_cols"]).to eq(5)
    end

    # The sandbox board cap used to be removed as a side effect of the
    # wholesale replace. Under a merge it has to be cleared deliberately.
    it "drops demo_board_limit when a sandbox is promoted" do
      user.update!(plan_type: "pro", plan_status: "active")
      communicator.update!(
        status: ChildAccount::SANDBOX,
        settings: { "demo_board_limit" => 1, "enable_image_display" => true },
      )

      update_settings({ enable_image_display: true }, status: ChildAccount::ACTIVE)

      expect(response).to have_http_status(:ok)
      settings = communicator.reload.settings
      expect(settings).not_to have_key("demo_board_limit")
      expect(settings["enable_image_display"]).to be(true)
    end

    it "keeps demo_board_limit while the account stays a sandbox" do
      communicator.update!(
        status: ChildAccount::SANDBOX,
        settings: { "demo_board_limit" => 1 },
      )

      update_settings({ enable_image_display: true }, is_demo: true)

      expect(communicator.reload.settings["demo_board_limit"]).to eq(1)
    end
  end

  # details is deliberately NOT merged — the frontend clears an AAC profile
  # field by deleting its key, so merging would make "Not set" a no-op.
  describe "details stays a wholesale replace" do
    it "drops a details key the caller omitted" do
      communicator.update!(details: { "aac_level" => "emerging", "age" => 7 })

      patch "/api/child_accounts/#{communicator.id}",
            params: { details: { age: 7 } }.to_json,
            headers: headers

      expect(response).to have_http_status(:ok)
      expect(communicator.reload.details).not_to have_key("aac_level")
    end
  end
end
