require "rails_helper"

# Regression coverage for #27 — strong-params permit lists must not let a client
# mass-assign ownership fields. The owner of a created/updated record is always
# derived server-side from the authenticated user, never from request params.
RSpec.describe "Mass-assignment of ownership fields", type: :request do
  let(:owner)    { create(:user) }
  let(:attacker) { create(:user) }

  describe "POST /api/child_accounts" do
    it "ignores a client-supplied user_id and owns the communicator to the caller" do
      post "/api/child_accounts",
           params: { name: "Sam", username: "sam-#{SecureRandom.hex(2)}", user_id: attacker.id },
           headers: auth_headers(owner)

      expect(response).to have_http_status(:created)
      child = ChildAccount.order(:id).last
      expect(child.owner_id).to eq(owner.id)
      expect(child.owner_id).not_to eq(attacker.id)
      expect(child.user_id).to eq(owner.id)
    end
  end
end
