require "rails_helper"

# Issue #930 (finding 2) — the public MySpeak payload said nothing about who was
# looking, so a signed-in Support member of a communicator's own team was shown
# the "Ask their family to add you to their team" panel.
#
# Contract: an AUTHENTICATED request for a communicator page carries
#   viewer: { team_member: true, role:, team_id:, is_owner: }
# or `viewer: { team_member: false }`. An anonymous request carries no `viewer`
# key at all — its body is exactly what it was before.
RSpec.describe "GET /api/profiles/public/:slug viewer relationship", type: :request do
  let(:owner) { FactoryBot.create(:user) }
  let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Oliver") }
  let!(:team) { child.ensure_team!(creator: owner) }
  let!(:profile) do
    Profile.create!(profileable: child, username: "oliver-#{SecureRandom.hex(3)}", slug: "oliver-#{SecureRandom.hex(3)}")
  end

  def fetch(headers: {})
    get "/api/profiles/public/#{profile.slug}", headers: headers
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body)
  end

  context "anonymous" do
    it "has no viewer key, and the body is the unchanged page view" do
      body = fetch

      expect(body).not_to have_key("viewer")
      expect(response.body).to eq(profile.reload.safety_view.to_json)
    end
  end

  context "signed in with no relationship to the communicator" do
    it "says team_member: false and nothing else" do
      stranger = FactoryBot.create(:user)

      expect(fetch(headers: auth_headers(stranger))["viewer"]).to eq("team_member" => false)
    end

    it "does not count membership of some other team" do
      stranger = FactoryBot.create(:user)
      other_owner = FactoryBot.create(:user)
      other_child = FactoryBot.create(:child_account, user: other_owner, owner: other_owner)
      other_child.ensure_team!(creator: other_owner).upsert_member!(stranger, "member")

      expect(fetch(headers: auth_headers(stranger))["viewer"]).to eq("team_member" => false)
    end
  end

  context "signed in as a team member" do
    it "names the stored role and the team" do
      support = FactoryBot.create(:user)
      team.upsert_member!(support, "member", accepted: false)

      expect(fetch(headers: auth_headers(support))["viewer"]).to eq(
        "team_member" => true, "role" => "member", "team_id" => team.id, "is_owner" => false,
      )
    end

    it "uses the role string exactly as stored" do
      slp = FactoryBot.create(:user)
      team.upsert_member!(slp, "supervisor")

      expect(fetch(headers: auth_headers(slp))["viewer"]["role"]).to eq("supervisor")
    end
  end

  context "signed in as the communicator's owner" do
    it "reports the owner's team role and is_owner: true" do
      expect(fetch(headers: auth_headers(owner))["viewer"]).to eq(
        "team_member" => true, "role" => "admin", "team_id" => team.id, "is_owner" => true,
      )
    end

    it "still reports team_member with role 'owner' when the owner holds no team row" do
      team.team_users.where(user_id: owner.id).delete_all

      expect(fetch(headers: auth_headers(owner))["viewer"]).to eq(
        "team_member" => true, "role" => "owner", "team_id" => team.id, "is_owner" => true,
      )
    end

    it "sends a null team_id when the communicator has no team" do
      team.team_users.delete_all
      team.team_accounts.delete_all

      expect(fetch(headers: auth_headers(owner))["viewer"]).to eq(
        "team_member" => true, "role" => "owner", "team_id" => nil, "is_owner" => true,
      )
    end
  end

  it "is not added to a signed-in request for a non-communicator page" do
    page_owner = FactoryBot.create(:user, plan_type: "pro")
    page = Profile.new(profileable: page_owner, username: "pro-#{SecureRandom.hex(3)}", slug: "pro-#{SecureRandom.hex(3)}")
    page.profile_kind = "public_page"
    page.save!

    get "/api/profiles/public/#{page.slug}", headers: auth_headers(owner)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).not_to have_key("viewer")
  end

  it "treats an invalid token as anonymous" do
    body = fetch(headers: { "Authorization" => "Bearer not-a-real-token" })

    expect(body).not_to have_key("viewer")
  end

  # The page is ETag-cached. A browser that cached the anonymous response must
  # not be handed a 304 for it once the viewer signs in — that would serve the
  # body without `viewer` and the panel would come back.
  it "does not revalidate an anonymous ETag for a signed-in viewer" do
    fetch
    anonymous_etag = response.headers["ETag"]
    expect(anonymous_etag).to be_present

    get "/api/profiles/public/#{profile.slug}", headers: { "If-None-Match" => anonymous_etag }
    expect(response).to have_http_status(:not_modified)

    get "/api/profiles/public/#{profile.slug}",
        headers: auth_headers(owner).merge("If-None-Match" => anonymous_etag)
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to have_key("viewer")
  end
end
