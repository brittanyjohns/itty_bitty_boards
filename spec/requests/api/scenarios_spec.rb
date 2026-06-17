require "rails_helper"

RSpec.describe "API::Scenarios", type: :request do
  let_it_be(:user, reload: true) { create(:user) }

  describe "POST /api/scenarios/suggestion" do
    let(:fake_client) { instance_double(OpenAI::Client) }

    before do
      allow(OpenAI::Client).to receive(:new).and_return(fake_client)
      allow(fake_client).to receive(:chat).and_return(
        "choices" => [{ "message" => { "content" => "una descripcion" } }],
      )
    end

    it "appends 'Respond in <language>' to the prompt when params[:language] is non-English" do
      post "/api/scenarios/suggestion",
           params: { name: "Doctor Visit", age_range: "4-6", language: "es" },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(fake_client).to have_received(:chat) do |arg|
        prompt = arg.dig(:parameters, :messages).find { |m| m[:role] == "user" }[:content]
        expect(prompt).to include("Respond in Spanish.")
      end
    end

    it "falls back to the requesting user's locale when params[:language] is absent" do
      user.update!(settings: (user.settings || {}).merge(voice: { language: "fr-FR" }))

      post "/api/scenarios/suggestion",
           params: { name: "Doctor Visit", age_range: "4-6" },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(fake_client).to have_received(:chat) do |arg|
        prompt = arg.dig(:parameters, :messages).find { |m| m[:role] == "user" }[:content]
        expect(prompt).to include("Respond in French.")
      end
    end

    it "does not append a 'Respond in' clause for English (no regression)" do
      post "/api/scenarios/suggestion",
           params: { name: "Doctor Visit", age_range: "4-6", language: "en" },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(fake_client).to have_received(:chat) do |arg|
        prompt = arg.dig(:parameters, :messages).find { |m| m[:role] == "user" }[:content]
        expect(prompt).not_to include("Respond in")
      end
    end
  end
end
