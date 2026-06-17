require "rails_helper"

RSpec.describe "API::Audits public word click", type: :request do
  let_it_be(:user, reload: true) { create(:user) }
  let_it_be(:account, reload: true) { create(:child_account, user: user) }
  let_it_be(:profile) { create(:profile, profileable: account) }
  let_it_be(:board) { create(:board, user: user) }

  before do
    allow_any_instance_of(API::AuditsController)
      .to receive(:get_ip_location).and_return({})
  end

  def public_params(overrides = {})
    { word: "hello", profileId: profile.id, boardId: board.id }.merge(overrides)
  end

  describe "POST /api/public_word_click" do
    it "creates a WordEvent" do
      expect {
        post "/api/public_word_click", params: public_params, as: :json
      }.to change(WordEvent, :count).by(1)
      expect(response).to have_http_status(:ok)
    end

    it "does not create a WordEvent when the communicator account has audit logging disabled" do
      account.update!(settings: { "disable_audit_logging" => true })

      expect {
        post "/api/public_word_click", params: public_params, as: :json
      }.not_to change(WordEvent, :count)
      expect(response).to have_http_status(:ok)
    end

    it "does not create a WordEvent when the board owner has audit logging disabled" do
      user.update!(settings: (user.settings || {}).merge("disable_audit_logging" => true))

      expect {
        post "/api/public_word_click", params: public_params, as: :json
      }.not_to change(WordEvent, :count)
      expect(response).to have_http_status(:ok)
    end
  end
end
