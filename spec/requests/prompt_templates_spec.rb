require 'rails_helper'

RSpec.describe "PromptTemplates", type: :request do
  let!(:prompt_template) { FactoryBot.create(:prompt_template) }

  describe "GET /index" do
    it "returns http success" do
      get "/prompt_templates"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /show" do
    it "returns http success" do
      get "/prompt_templates/#{prompt_template.id}"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /new" do
    it "returns http success" do
      get "/prompt_templates/new"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /edit" do
    it "returns http success" do
      get "/prompt_templates/#{prompt_template.id}/edit"
      expect(response).to have_http_status(:success)
    end
  end

end
