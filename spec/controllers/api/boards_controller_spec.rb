require "rails_helper"

RSpec.describe API::BoardsController, type: :controller do
  let!(:user) { FactoryBot.create(:user) }
  let!(:board) { FactoryBot.create(:board, user: user, layout: {}) }
  let!(:board_image1) { FactoryBot.create(:board_image, board: board, layout: {}) }
  let!(:board_image2) { FactoryBot.create(:board_image, board: board, layout: {}) }
  let(:layout) do
    [
      { "i" => board_image1.id.to_s, "x" => 0, "y" => 0, "w" => 1, "h" => 1 },
      { "i" => board_image2.id.to_s, "x" => 1, "y" => 0, "w" => 1, "h" => 1 },
    ]
  end

  before do
    request.headers["Authorization"] = "Bearer #{user.authentication_token}" if user.authentication_token.present?
  end

  describe "POST #save_layout" do
    it "updates the board layout and returns the updated board with images" do
      expect(Board).to receive(:with_artifacts).and_return(Board)
      expect(Board).to receive(:find).with(board.id.to_s).and_return(board)
      expect(board).to receive(:update_grid_layout).with(layout, "lg").and_call_original

      post :save_layout, params: { id: board.id, layout: layout, screen_size: "lg" }, as: :json

      board.reload

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)
      puts "\n\njson_response:\n\n"
      pp json_response

      expect(json_response["id"]).to eq(board.id)
      expect(json_response["images"].length).to eq(2)
      expect(board.layout["lg"].length).to eq(2)
      expect(board.layout["lg"].first["i"]).to eq(board_image1.id.to_s)
      expect(board.layout["lg"].second["i"]).to eq(board_image2.id.to_s)
    end

    it "defaults to large screen layout if screen_size is not provided" do
      post :save_layout, params: { id: board.id, layout: layout }, as: :json

      board.reload

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)

      expect(json_response["id"]).to eq(board.id)
      expect(board.layout["lg"].length).to eq(2)
    end
  end

  # describe "POST #import_from_obf" do
  #   let(:obf_zip_file_path) { Rails.root.join("spec", "data", "path_images.obz") }
  #   let(:obf_zip_file) { File.open(obf_zip_file_path) }
  #   let(:extracted_data) { OBF::OBZ.to_external(obf_zip_file, {}) }
  #   let(:file_name) { File.basename(obf_zip_file) }
  #   let(:root_board_id) { nil }

  #   before do
  #     Zip::File.open(obf_zip_file.path) do |zip_file|
  #       zip_file.each do |entry|
  #         if entry.name == "manifest.json"
  #           manifest = JSON.parse(entry.get_input_stream.read)
  #           root_board_id = manifest["root"]
  #         end
  #       end
  #     end
  #   end

  #   it "imports from OBZ file" do
  #     json_data = {
  #       extracted_obz_data: extracted_data,
  #       current_user_id: user.id,
  #       group_name: file_name,
  #       root_board_id: root_board_id,
  #     }.to_json

  #     expect(ImportFromObfJob).to receive(:new).and_call_original
  #     expect_any_instance_of(ImportFromObfJob).to receive(:perform).with(json_data)

  #     post :import_from_obf, params: { obz_file: obf_zip_file }, as: :json

  #     expect(response).to have_http_status(:ok)
  #   end
  # end
end
