require "rails_helper"

RSpec.describe "API::Menus", type: :request do
  let(:user) { create(:user) }

  describe "POST /api/menus" do
    let(:image) do
      Rack::Test::UploadedFile.new(
        Rails.root.join("spec/data/path_images/images/happy.png"), "image/png"
      )
    end

    it "requires authentication" do
      post "/api/menus", params: { menu: { name: "Lunch" } }
      expect(response).to have_http_status(:unauthorized)
    end

    it "creates a menu board from a name and image with no extracted text" do
      expect {
        post "/api/menus",
             params: { menu: { name: "Joe's Diner", docs: { image: image } } },
             headers: auth_headers(user)
      }.to change(Menu, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["name"]).to eq("Joe's Diner")
      expect(body["boardId"]).to be_present
    end

    it "enqueues the vision extraction job" do
      expect {
        post "/api/menus",
             params: { menu: { name: "Joe's Diner", docs: { image: image } } },
             headers: auth_headers(user)
      }.to change(EnhanceImageDescriptionJob.jobs, :size).by(1)
    end
  end
end
