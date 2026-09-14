require "rails_helper"

# A communicator's likeness lives in settings["likeness"]: allowlisted tokens,
# replaced whole by the picker, and shown only to someone who may edit the
# communicator.
RSpec.describe "Communicator likeness settings", type: :request do
  let(:owner) { create(:user) }
  let(:communicator) { create(:child_account, user: owner) }
  let(:headers) { auth_headers(owner).merge("Content-Type" => "application/json") }

  def update_settings(settings)
    patch "/api/child_accounts/#{communicator.id}", params: { settings: settings }.to_json, headers: headers
  end

  it "stores the normalized likeness and drops anything off the allowlist" do
    update_settings(likeness: { skin_tone: "Brown", hair_color: "draw a cartoon", extras: %w[glasses cape] })

    expect(response).to have_http_status(:ok)
    expect(communicator.reload.settings["likeness"]).to eq("skin_tone" => "brown", "extras" => ["glasses"])
    expect(communicator.likeness.skin_tone).to eq("brown")
  end

  it "leaves the rest of settings alone" do
    communicator.update!(settings: (communicator.settings || {}).merge("large_layout_cols" => 4))

    update_settings(likeness: { skin_tone: "light" })

    expect(communicator.reload.settings["large_layout_cols"]).to eq(4)
  end

  it "replaces the likeness whole, so a field left out is cleared" do
    update_settings(likeness: { skin_tone: "light", hair_color: "red" })
    update_settings(likeness: { skin_tone: "light" })

    expect(communicator.reload.settings["likeness"]).to eq("skin_tone" => "light")
  end

  it "removes the key when nothing usable is sent" do
    update_settings(likeness: { skin_tone: "light" })
    update_settings(likeness: {})

    expect(communicator.reload.settings).not_to have_key("likeness")
  end

  describe "who sees it" do
    before { communicator.update!(settings: { "likeness" => { "skin_tone" => "dark_brown" } }) }

    it "is in the owner's payload" do
      expect(communicator.reload.api_view(owner)[:settings]["likeness"]).to eq("skin_tone" => "dark_brown")
    end

    it "is withheld from anyone who cannot edit the communicator" do
      expect(communicator.reload.api_view(create(:user))[:settings]).not_to have_key("likeness")
      expect(communicator.reload.api_view(nil)[:settings]).not_to have_key("likeness")
    end
  end
end
