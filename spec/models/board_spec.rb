# == Schema Information
#
# Table name: boards
#
#  id                    :bigint           not null, primary key
#  user_id               :bigint           not null
#  name                  :string
#  parent_type           :string           not null
#  parent_id             :bigint           not null
#  description           :text
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  cost                  :integer          default(0)
#  predefined            :boolean          default(FALSE)
#  token_limit           :integer          default(0)
#  voice                 :string
#  status                :string           default("pending")
#  number_of_columns     :integer          default(6)
#  small_screen_columns  :integer          default(3)
#  medium_screen_columns :integer          default(8)
#  large_screen_columns  :integer          default(12)
#  display_image_url     :string
#  layout                :jsonb
#  position              :integer
#  audio_url             :string
#  bg_color              :string
#  margin_settings       :jsonb
#  settings              :jsonb
#  category              :string
#  data                  :jsonb
#  group_layout          :jsonb
#  image_parent_id       :integer
#  board_type            :string
#  obf_id                :string
#  board_group_id        :integer
#
require "rails_helper"

RSpec.describe Board, type: :model do
  after(:each) do
    BoardGroup.destroy_all
    BoardImage.destroy_all
    Board.destroy_all
  end
  let!(:board) { FactoryBot.create(:board, user: user, layout: {}, medium_screen_columns: 2, large_screen_columns: 3, small_screen_columns: 1) }
  let!(:user) { FactoryBot.create(:user) }
  describe "#calculate_grid_layout_for_screen_size" do
    let!(:board_image1) { FactoryBot.create(:board_image, position: 1, board: board, layout: {}) }
    let!(:board_image2) { FactoryBot.create(:board_image, position: 2, board: board, layout: {}) }

    before do
      board.board_images << [board_image1, board_image2]
      # board.reset_layouts
    end
    it "calculates the grid layout based on screen size and column count" do
      board.medium_screen_columns = 2
      board.calculate_grid_layout_for_screen_size("md")
      board_image1.reload
      board_image2.reload

      expect(board_image1.layout["md"]["x"]).to eq(0)
      expect(board_image1.layout["md"]["y"]).to eq(0)
      expect(board_image2.layout["md"]["x"]).to eq(1)
      expect(board_image2.layout["md"]["y"]).to eq(0)
      api_view = board.api_view_with_images(user)
    end

    it "handles cases where there are more images than columns" do
      board.medium_screen_columns = 1
      board.calculate_grid_layout_for_screen_size("md")
      board_image1.reload
      board_image2.reload

      expect(board_image1.layout["md"]["x"]).to eq(0)
      expect(board_image1.layout["md"]["y"]).to eq(0)
      expect(board_image2.layout["md"]["x"]).to eq(0)
      expect(board_image2.layout["md"]["y"]).to eq(1)
    end
  end

  describe "#set_layouts_for_screen_sizes" do
    it "sets layouts for all screen sizes" do
      allow(board).to receive(:calculate_grid_layout_for_screen_size).and_call_original

      board.set_layouts_for_screen_sizes

      expect(board).to have_received(:calculate_grid_layout_for_screen_size).with("sm", true)
      expect(board).to have_received(:calculate_grid_layout_for_screen_size).with("md", true)
      expect(board).to have_received(:calculate_grid_layout_for_screen_size).with("lg", true)
    end
  end

  describe "#reset_layouts" do
    let!(:board_image1) { FactoryBot.create(:board_image, position: 1, board: board, layout: {}) }
    let!(:board_image2) { FactoryBot.create(:board_image, position: 2, board: board, layout: {}) }
    it "resets and recalculates layouts" do
      board.layout = { "md" => { board_image1.id => { x: 1, y: 1, w: 1, h: 1 } } }

      board.reset_layouts

      expect(board.layout["md"]).not_to eq({ board_image1.id => { x: 1, y: 1, w: 1, h: 1 } })
      expect(board.layout["md"]).to be_present
    end
  end

  describe "#update_grid_layout" do
    let!(:board_image1) { FactoryBot.create(:board_image, position: 1, board: board, layout: {}) }
    let!(:board_image2) { FactoryBot.create(:board_image, position: 2, board: board, layout: {}) }
    it "updates the layout for the specified screen size" do
      layout_to_set = [{ "i" => board_image1.id.to_s, "x" => 0, "y" => 0, "w" => 1, "h" => 1 }]
      board.update_grid_layout(layout_to_set, "md")

      expect(board_image1.reload.layout["md"]).to eq(layout_to_set.first)
      expect(board.layout["md"]).to eq(layout_to_set)
    end

    it "updates the layout for the specified screen size and does not affect other screen sizes" do
      layout_to_set = [{ "i" => board_image1.id.to_s, "x" => 0, "y" => 0, "w" => 1, "h" => 1 }]
      board.update_grid_layout(layout_to_set, "md")

      expect(board_image1.reload.layout["md"]).to eq(layout_to_set.first)
      expect(board_image1.layout["sm"]).to be_nil
    end

    context "board image has existing layout" do
      it "updates the layout for the specified screen size" do
        layout_to_set = [{ "i" => board_image1.id.to_s, "x" => 0, "y" => 0, "w" => 1, "h" => 1 }]
        board_image1.layout["md"] = { "x" => 1, "y" => 1, "w" => 1, "h" => 1 }
        board_image1.save

        board.update_grid_layout(layout_to_set, "md")

        expect(board_image1.reload.layout["md"]).to eq(layout_to_set.first)
        expect(board.layout["md"]).to eq(layout_to_set)
      end
    end
  end

  describe "#api_view_with_images" do
    let!(:board_image1) { FactoryBot.create(:board_image, position: 1, board: board, layout: {}) }
    let!(:board_image2) { FactoryBot.create(:board_image, position: 2, board: board, layout: {}) }
    it "returns the expected JSON structure" do
      board.reload
      json_response = board.api_view_with_images(user)

      expect(json_response).to include(
        :id,
        :name,
        :description,
        :parent_type,
        :predefined,
        :number_of_columns,
        :status,
        :token_limit,
        :cost,
        :display_image_url,
        :images
      )
      expect(json_response[:images].size).to eq(2)
      expect(json_response[:images].first).to include(
        :id,
        :board_image_id,
        :label,
        :src,
        :voice,
        :layout
      )
    end
    it "returns the expected JSON structure" do
      layout_to_set = [{ "i" => board_image1.id.to_s, "x" => 0, "y" => 0, "w" => 1, "h" => 1 }]
      board.update_grid_layout(layout_to_set, "md")
      board.reload
      json_response = board.api_view_with_images(user)

      expect(json_response[:images].first[:layout]["md"]).to eq({ "i" => board_image1.id.to_s, "x" => 0, "y" => 0, "w" => 1, "h" => 1 })
    end
  end

  describe "#rearrange_images" do
    it "returns the expected layout" do
      board.rearrange_images

      expect(board.layout).to be_present
    end
  end

  describe "#print_grid_layout" do
    it "prints the grid layout" do
      board.print_grid_layout

      expect(board.layout).to be_present
    end
  end

  describe "#parse_obf_grid" do
    let!(:user) { FactoryBot.create(:user) }
    let!(:board) { Board.create!(name: "test board", user: user, parent_id: user.id, parent_type: "User") }
    let!(:image_1) { Image.create(label: "test image 1") }
    let!(:image_2) { Image.create(label: "test image 2") }
    let(:obf_grid) { { "rows" => 2, "columns" => 2, "order" => [[nil, board_image_1.id], [nil, board_image_2.id]] } }
    let(:expected_layout) { [{ "i" => board_image_1.id.to_s, "x" => 1, "y" => 0, "w" => 1, "h" => 1 }, { "i" => board_image_2.id.to_s, "x" => 2, "y" => 0, "w" => 1, "h" => 1 }] }
    before do
      board.add_image(image_1.id)
      board.add_image(image_2.id)
    end
    let!(:board_image_1) { board.board_images.first }
    let!(:board_image_2) { board.board_images.last }
    it "parses the OBF grid" do
      board.parse_obf_grid(obf_grid)

      expect(board.layout).to be_present
      expect(board.print_grid_layout_for_screen_size("lg")).to eq(expected_layout)
    end
  end

  describe ".from_obf" do
    it "creates a new board from an OBF file" do
      obf_file = Rails.root.join("spec", "data", "test.obf")
      data = JSON.parse(File.read(obf_file))
      grid_order = data["grid"]["order"]
      expected_board_image_count = data["images"].size
      root_board_id = data["id"]
      board_group = BoardGroup.create!(name: "Test", user: user, original_obf_root_id: root_board_id)
      board, _dynamic_data = Board.from_obf(obf_file, user, board_group)

      last_bi_layout = board.board_images.last.layout

      expect(board).to be_present
      expect(board.board_images.size).to eq(expected_board_image_count)
      expect(last_bi_layout).to be_present
    end

    context "when the OBF file has image paths" do
      it "creates a new board from an OBF file" do
        obf_file = Rails.root.join("spec", "data", "path_images", "boards", "path_images.obf")
        data = JSON.parse(File.read(obf_file))
        grid_order = data["grid"]["order"]
        expected_board_image_count = data["images"].size
        board, dynamic_data = Board.from_obf(obf_file, user)

        last_bi_layout = board.board_images.last.layout
        pp dynamic_data

        expect(board).to be_present
        expect(board.board_images.size).to eq(expected_board_image_count)
        expect(last_bi_layout).to be_present
      end
    end
  end

  describe ".from_obz" do
    it "creates a zip file containing an OBF file and all the images, other files referenced by the OBF file" do
      obf_zip_file_path = Rails.root.join("spec", "data", "ck12.obz")
      # extracted_data = Board.extract_obz(obf_zip_file)
      extracted_data = OBF::OBZ.to_external(obf_zip_file_path, {})
      file_name = File.basename(obf_zip_file_path)
      @get_manifest_data = Board.extract_manifest(obf_zip_file_path)
      Rails.logger.debug "Manifest data: #{@get_manifest_data}"
      parsed_manifest = JSON.parse(@get_manifest_data)

      puts "parsed_manifest: #{parsed_manifest}"
      @root_board_id = parsed_manifest["root"]

      # Write the extracted data to a file

      # puts "extracted_data:\n"
      # pp extracted_data
      expected_board_image_count = extracted_data["boards"].size
      first_board = extracted_data["boards"].first
      expect(extracted_data).to be_present

      result = Board.from_obz(extracted_data, user, file_name, first_board["id"])
      first_board_id = result.first.with_indifferent_access[:board_id]
      second_board_id = result.second.with_indifferent_access[:board_id]
      pp result
      first_board = Board.find(first_board_id)
      second_board = Board.find(second_board_id)

      expect(first_board).to be_present
      expect(first_board.board_type).to eq("dynamic")
      expect(second_board).to be_present
      expect(second_board.board_type).to eq("predictive")

      # expect(first_board.board_images.count).to eq(expected_board_image_count)
      # first_board_board_image = first_board.board_images.first
      # first_board_image = first_board_board_image.image
      # docs = first_board_image.docs
      # puts "first_board_image: #{first_board_image.inspect}"
      # puts "docs: #{docs.inspect}"
      # doc_image = docs.first.image if docs.present?
      # # puts "docs: #{docs.inspect}"
      # expect(docs.count).to eq(1)
      # expect(doc_image).to be_present
      # pp extracted_data["boards"]
    end
  end

  describe ".extract_manifest" do
    it "extracts the manifest from an OBZ file" do
      obf_zip_file_path = Rails.root.join("spec", "data", "ck12.obz")
      manifest = Board.extract_manifest(obf_zip_file_path)
      parsed_manifest = JSON.parse(manifest)

      root_board_id_key = parsed_manifest["root"]
      paths = parsed_manifest["paths"]
      boards = paths["boards"]
      root_board_id = boards.key(root_board_id_key)
      expect(manifest).to be_present
    end
  end

  describe ".analyze_manifest" do
    it "analyzes the manifest from an OBZ file" do
      obf_zip_file_path = Rails.root.join("spec", "data", "ck12.obz")
      manifest = Board.extract_manifest(obf_zip_file_path)
      parsed_manifest = Board.analyze_manifest(manifest)
      puts "parsed_manifest: #{parsed_manifest}"

      board_count = parsed_manifest["board_count"]
      image_count = parsed_manifest["image_count"]
      root_board_id = parsed_manifest["root_board_id"]

      expect(parsed_manifest).to be_present
    end
  end
end
