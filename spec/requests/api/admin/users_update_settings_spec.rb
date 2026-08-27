require "rails_helper"

# The admin settings form submits ONLY the fields an admin touched, so an
# absent key means "leave it alone". Reading absent as `false` turned off the
# symbol strip (`enable_image_display` defaults to true) for every user whose
# plan an admin edited, with nothing in the UI saying so — and `ensure_settings`
# never repaired it, because it only fills a nil, never a stored `false`.
RSpec.describe "API::Admin::Users settings update", type: :request do
  let!(:admin) { create(:admin_user) }
  let!(:user) { create(:user) }
  let(:headers) { auth_headers(admin) }

  def update_user(user_setting)
    put "/api/admin/users/#{user.id}",
        params: { user_setting: user_setting },
        headers: headers
  end

  before do
    user.update!(settings: user.settings.merge(
      "enable_image_display" => true,
      "enable_text_display" => true,
      "wait_to_speak" => true,
      "show_labels" => true,
      "voice" => { "name" => "polly:joanna", "language" => "en-US" },
    ))
  end

  it "leaves display settings untouched when the payload omits them" do
    update_user(plan_type: "pro")

    expect(response).to have_http_status(:ok)
    settings = user.reload.settings
    expect(settings["enable_image_display"]).to be(true)
    expect(settings["enable_text_display"]).to be(true)
    expect(settings["wait_to_speak"]).to be(true)
    expect(settings["show_labels"]).to be(true)
    expect(user.plan_type).to eq("pro")
  end

  it "writes false when the admin sends it explicitly" do
    update_user(enable_image_display: false, enable_text_display: false)

    settings = user.reload.settings
    expect(settings["enable_image_display"]).to be(false)
    expect(settings["enable_text_display"]).to be(false)
  end

  it "casts checkbox-style string values to booleans" do
    update_user(enable_image_display: "0", wait_to_speak: "1")

    settings = user.reload.settings
    expect(settings["enable_image_display"]).to be(false)
    expect(settings["wait_to_speak"]).to be(true)
  end

  it "lets an admin set show_labels and show_tutorial" do
    update_user(show_labels: false, show_tutorial: false)

    settings = user.reload.settings
    expect(settings["show_labels"]).to be(false)
    expect(settings["show_tutorial"]).to be(false)
  end

  it "keeps the stored voice when the payload omits it" do
    update_user(plan_type: "pro")

    expect(user.reload.settings["voice"]).to include("name" => "polly:joanna")
  end

  it "replaces the voice under the string key when one is sent" do
    update_user(voice: { name: "polly:kevin", language: "en-US" })

    settings = user.reload.settings
    expect(settings["voice"]).to include("name" => "polly:kevin")
    expect(settings.keys).not_to include(:voice)
  end
end
