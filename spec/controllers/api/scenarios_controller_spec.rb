require "rails_helper"

RSpec.describe API::ScenariosController, type: :controller do
  let!(:user) { FactoryBot.create(:user) }

  before do
    request.headers["Authorization"] = "Bearer #{user.authentication_token}" if user.authentication_token.present?
  end

  describe "POST #suggestion" do
    let(:valid_params) { { name: "First day of school", age_range: "5-7" } }

    it "renders 422 when name is missing" do
      post :suggestion, params: { age_range: "5-7" }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/cannot be blank/i)
    end

    it "renders 422 when age_range is missing" do
      post :suggestion, params: { name: "X" }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "delegates to OpenAiClient#generate_scenario_description and returns it" do
      fake_client = instance_double(OpenAiClient)
      expect(OpenAiClient).to receive(:new).with({}).and_return(fake_client)
      expect(fake_client).to receive(:generate_scenario_description).with("First day of school", "5-7").and_return("Arriving at school. Meeting the teacher. Finding the bathroom.")

      post :suggestion, params: valid_params, as: :json

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["description"]).to eq("Arriving at school. Meeting the teacher. Finding the bathroom.")
    end

    it "renders 502 when OpenAiClient returns nil" do
      fake_client = instance_double(OpenAiClient, generate_scenario_description: nil)
      allow(OpenAiClient).to receive(:new).and_return(fake_client)

      post :suggestion, params: valid_params, as: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(JSON.parse(response.body)["error"]).to match(/could not generate/i)
    end

    it "renders 502 when OpenAiClient returns blank string" do
      fake_client = instance_double(OpenAiClient, generate_scenario_description: "   ")
      allow(OpenAiClient).to receive(:new).and_return(fake_client)

      post :suggestion, params: valid_params, as: :json

      expect(response).to have_http_status(:bad_gateway)
    end

    it "does not call OpenAiClient when params are invalid" do
      expect(OpenAiClient).not_to receive(:new)
      post :suggestion, params: { name: "", age_range: "" }, as: :json
    end
  end
end
