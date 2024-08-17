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
#
require "rails_helper"

RSpec.describe Board, type: :model do
  let!(:user) { FactoryBot.create(:user) }
  let!(:board) { FactoryBot.create(:board, user: user, layout: {}, medium_screen_columns: 2, large_screen_columns: 3, small_screen_columns: 1) }
  let!(:board_image1) { FactoryBot.create(:board_image, position: 1, board: board, layout: {}) }
  let!(:board_image2) { FactoryBot.create(:board_image, position: 2, board: board, layout: {}) }

  before do
    board.board_images << [board_image1, board_image2]
    # board.reset_layouts
  end

  describe "#calculate_grid_layout_for_screen_size" do
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
      puts "board.print_grid_layout: #{api_view[:images].first[:layout]}"
    end

    it "handles cases where there are more images than columns" do
      board.medium_screen_columns = 1
      board.calculate_grid_layout_for_screen_size("md")
      puts "test-Board layout: #{board_image1.layout}"
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

      expect(board).to have_received(:calculate_grid_layout_for_screen_size).with("sm")
      expect(board).to have_received(:calculate_grid_layout_for_screen_size).with("md")
      expect(board).to have_received(:calculate_grid_layout_for_screen_size).with("lg")
    end
  end

  describe "#reset_layouts" do
    it "resets and recalculates layouts" do
      board.layout = { "md" => { board_image1.id => { x: 1, y: 1, w: 1, h: 1 } } }

      board.reset_layouts

      expect(board.layout["md"]).not_to eq({ board_image1.id => { x: 1, y: 1, w: 1, h: 1 } })
      expect(board.layout["md"]).to be_present
    end
  end

  describe "#update_grid_layout" do
    it "updates the layout for the specified screen size" do
      layout_to_set = [{ "i" => board_image1.id.to_s, "x" => 0, "y" => 0, "w" => 1, "h" => 1 }]
      puts "before test-Board layout: #{board.layout}"
      board.update_grid_layout("md")

      expect(board_image1.reload.layout["md"]).to eq(layout_to_set.first)
      expect(board.layout["md"]).to eq(layout_to_set)
    end

    it "updates the layout for the specified screen size and does not affect other screen sizes" do
      layout_to_set = [{ "i" => board_image1.id.to_s, "x" => 0, "y" => 0, "w" => 1, "h" => 1 }]
      board.update_grid_layout("md")

      expect(board_image1.reload.layout["md"]).to eq(layout_to_set.first)
      expect(board_image1.layout["sm"]).to be_nil
    end

    context "board image has existing layout" do
      it "updates the layout for the specified screen size" do
        layout_to_set = [{ "i" => board_image1.id.to_s, "x" => 0, "y" => 0, "w" => 1, "h" => 1 }]
        board_image1.layout["md"] = { "x" => 1, "y" => 1, "w" => 1, "h" => 1 }
        board_image1.save

        board.update_grid_layout("md")

        expect(board_image1.reload.layout["md"]).to eq(layout_to_set.first)
        expect(board.layout["md"]).to eq(layout_to_set)
      end
    end
  end

  describe "#api_view_with_images" do
    it "returns the expected JSON structure" do
      board.reload
      json_response = board.api_view_with_images(user)

      puts "json_response[:images].first: #{json_response[:images].first[:layout]}"

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
      board.update_grid_layout("md")
      board.reload
      json_response = board.api_view_with_images(user)

      puts "json_response[:images].first: #{json_response[:images].first[:layout]}"

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
end
