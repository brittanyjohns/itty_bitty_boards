require "rails_helper"

# A communicator's board reads the same display flags its owner's board does,
# but only User seeded them server-side — so a communicator whose settings blob
# the frontend never wrote carried neither key, and the effective default came
# from whichever form had created it (`?? true` on one, `|| false` on another).
RSpec.describe ChildAccount, "settings defaults" do
  let(:user) { create(:user) }

  it "seeds the full default set on create" do
    communicator = create(:child_account, user: user)

    settings = communicator.reload.settings
    expect(settings["enable_image_display"]).to be(true)
    expect(settings["show_labels"]).to be(true)
    expect(settings["show_tutorial"]).to be(true)
    expect(settings["enable_text_display"]).to be(false)
    expect(settings["wait_to_speak"]).to be(false)
    expect(settings["disable_audit_logging"]).to be(false)
  end

  it "defaults the same keys to the same values User does" do
    communicator = create(:child_account, user: user)

    shared = DisplaySettingsDefaults::REQUIRED_SETTINGS
    expect(communicator.reload.settings.slice(*shared))
      .to eq(user.reload.settings.slice(*shared))
  end

  it "never overwrites a stored false" do
    communicator = create(:child_account, user: user, settings: { "enable_image_display" => false })

    expect(communicator.reload.settings["enable_image_display"]).to be(false)
  end

  it "fills only the missing keys on a later save" do
    communicator = create(:child_account, user: user)
    communicator.update_column(:settings, { "enable_text_display" => true })

    communicator.reload.update!(name: "Renamed")

    settings = communicator.reload.settings
    expect(settings["enable_text_display"]).to be(true)
    expect(settings["enable_image_display"]).to be(true)
  end

  it "handles a nil settings column" do
    communicator = create(:child_account, user: user)
    communicator.update_column(:settings, nil)

    expect { communicator.reload.save! }.not_to raise_error
    expect(communicator.reload.settings["enable_image_display"]).to be(true)
  end
end
