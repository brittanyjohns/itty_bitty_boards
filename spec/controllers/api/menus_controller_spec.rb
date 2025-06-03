require "rails_helper"

RSpec.describe API::MenusController, type: :controller do
  let!(:user) { FactoryBot.create(:user) }

  before do
    request.headers["Authorization"] = "Bearer #{user.authentication_token}" if user.authentication_token.present?
  end

  describe "GET #index" do
    it "returns a list of menus for the current user" do
      menu1 = FactoryBot.create(:menu, user: user)
      menu2 = FactoryBot.create(:menu, user: user)
      get :index, as: :json
      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)
      expect(json_response["user"].length).to eq(2)
      expect(json_response["user"].map { |m| m["id"] }).to include(menu1.id, menu2.id)
      expect(json_response["predefined"]).to be_empty
    end
  end
  describe "GET #show" do
    it "returns the specified menu" do
      menu = FactoryBot.create(:menu, user: user)
      get :show, params: { id: menu.id }, as: :json
      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)
      expect(json_response["id"]).to eq(menu.id)
      expect(json_response["name"]).to eq(menu.name)
    end

    # it "returns a 404 for a non-existent menu" do
    #   get :show, params: { id: 9999 }, as: :json
    #   json_response = JSON.parse(response.body)
    #   expect(json_response["error"]).to eq("Menu not found")
    #   expect(response).to have_http_status(:not_found)
    # end
  end
  describe "POST #create" do
    it "creates a new menu" do
      post :create, params: { menu: { name: "New Menu", description: "Test Description" } }, as: :json
      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)
      expect(json_response["name"]).to eq("New Menu")
      expect(json_response["description"]).to eq("Test Description")
      expect(json_response["user_id"]).to eq(user.id)
    end
  end
end
