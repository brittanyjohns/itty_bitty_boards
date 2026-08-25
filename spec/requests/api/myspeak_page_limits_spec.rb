require "rails_helper"

# Regression suite for #761. Adding a communicator auto-mints its MySpeak
# Profile (ChildAccount#create_profile!), and that Profile used to be counted
# against a separate per-user "MySpeak ID" limit of 1 — so a Free user who added
# one communicator through the dashboard could never create anything else, via a
# path (POST /api/child_accounts) that never knew the limit existed.
#
# The rule now: a communicator's MySpeak page is free on every plan and the
# COMMUNICATOR SLOT is its only quota; the user-level Public page is a separate
# product, one per user.
RSpec.describe "MySpeak page limits", type: :request do
  let(:free_user) do
    u = create(:user, created_at: 2.months.ago)
    u.setup_free_limits
    u.save!
    u
  end

  it "lets a Free user create their own Public page after adding a communicator" do
    post "/api/child_accounts",
      params: {
        name: "My Kid",
        username: "my-kid-#{SecureRandom.hex(3)}",
        status: "sandbox",
        password: "abcdef",
        password_confirmation: "abcdef",
      },
      headers: auth_headers(free_user)
    expect(response).to have_http_status(:created)

    communicator = ChildAccount.find_by(owner_id: free_user.id)
    # The communicator's MySpeak page is minted silently — this is the Profile
    # that used to burn the user's only slot.
    expect(communicator.profile).to be_present

    expect {
      post "/api/profiles",
        params: { profile: { username: "pat-#{SecureRandom.hex(2)}" } },
        headers: auth_headers(free_user)
    }.to change { Profile.where(profileable: free_user).count }.by(1)

    expect(response).to have_http_status(:created)
  end
end
