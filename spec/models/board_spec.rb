# == Schema Information
#
# Table name: boards
#
#  id                         :bigint           not null, primary key
#  user_id                    :bigint
#  name                       :string
#  parent_type                :string           not null
#  parent_id                  :bigint           not null
#  description                :text
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#  cost                       :integer          default(0)
#  predefined                 :boolean          default(FALSE)
#  token_limit                :integer          default(0)
#  voice                      :string
#  status                     :string           default("pending")
#  number_of_columns          :integer          default(6)
#  small_screen_columns       :integer          default(3)
#  medium_screen_columns      :integer          default(8)
#  large_screen_columns       :integer          default(12)
#  display_image_url          :string
#  layout                     :jsonb
#  position                   :integer
#  audio_url                  :string
#  bg_color                   :string
#  margin_settings            :jsonb
#  settings                   :jsonb
#  category                   :string
#  data                       :jsonb
#  group_layout               :jsonb
#  image_parent_id            :integer
#  board_type                 :string
#  obf_id                     :string
#  language                   :string           default("en")
#  board_images_count         :integer          default(0), not null
#  published                  :boolean          default(FALSE)
#  favorite                   :boolean          default(FALSE)
#  vendor_id                  :bigint
#  slug                       :string           default("")
#  in_use                     :boolean          default(FALSE), not null
#  is_template                :boolean          default(FALSE), not null
#  board_screenshot_import_id :bigint
#  sub_board                  :boolean          default(TRUE), not null
#  generated_token            :string
#  generated_token_expires_at :datetime
#  metadata                   :jsonb
#  tags                       :string           default([]), not null, is an Array
#
require "rails_helper"

RSpec.describe Board, type: :model do
  describe "#clone_with_images" do
    let(:user)  { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user, name: "Original Board") }
    let(:image) { FactoryBot.create(:image, user: user) }
    before { FactoryBot.create(:board_image, board: board, image: image) }

    it "creates a new board with the same name by default" do
      cloned = board.clone_with_images(user.id)
      expect(cloned).to be_a(Board)
      expect(cloned.id).not_to eq(board.id)
      expect(cloned.name).to eq("Original Board")
    end

    it "accepts a custom name" do
      cloned = board.clone_with_images(user.id, "Cloned Board")
      expect(cloned.name).to eq("Cloned Board")
    end

    it "assigns the cloned board to the target user" do
      other_user = FactoryBot.create(:user)
      cloned = board.clone_with_images(other_user.id)
      expect(cloned.user_id).to eq(other_user.id)
    end

    it "does not mark the clone as predefined" do
      board.update!(predefined: true)
      cloned = board.clone_with_images(user.id)
      expect(cloned.predefined).to be false
    end

    it "copies board images to the new board" do
      cloned = board.clone_with_images(user.id)
      expect(cloned.board_images.count).to eq(board.board_images.count)
    end
  end

  describe "#update_grid_layout" do
    let(:user)  { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user, layout: { "lg" => [] }) }

    it "does nothing when given a non-array layout" do
      expect { board.update_grid_layout("invalid", "lg") }.not_to raise_error
    end

    it "does nothing when given an empty array" do
      expect { board.update_grid_layout([], "lg") }.not_to raise_error
    end

    it "updates layout for the given screen size when board_image exists" do
      image      = FactoryBot.create(:image, user: user)
      bi         = FactoryBot.create(:board_image, board: board, image: image)
      layout_item = { "i" => bi.id.to_s, "x" => 0, "y" => 0, "w" => 1, "h" => 1 }

      board.update_grid_layout([layout_item], "lg")
      board.reload

      expect(board.layout["lg"]).to be_present
      expect(board.layout["lg"].first["i"]).to eq(bi.id.to_s)
    end
  end

  describe ".find_or_create_images_from_word_list" do
    let(:user) { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user) }

    context "when all words are new" do
      it "creates new images for each word" do
        words = ["apple", "banana", "cherry"]
        expect {
          board.find_or_create_images_from_word_list(words)
        }.to change(Image, :count).by(3)
        expect(board.images.pluck(:label)).to match_array(words)
      end
    end

    context "when some words already exist" do
      context "by the admin user" do
        let(:admin_user) { FactoryBot.create(:user, role: "admin", id: User::DEFAULT_ADMIN_ID) }
        before do
          FactoryBot.create(:image, label: "apple", user: admin_user)
        end

        it "creates images only for the new words" do
          words = ["apple", "banana", "cherry"]
          expect {
            board.find_or_create_images_from_word_list(words)
          }.to change(Image, :count).by(2)
          expect(board.images.pluck(:label)).to match_array(words)
        end
      end

      context "by another regular user" do
        let(:other_user) { FactoryBot.create(:user) }
        before do
          FactoryBot.create(:image, label: "apple", user: other_user)
        end

        it "creates images for all words since existing image is by a different user" do
          words = ["apple", "banana", "cherry"]
          expect {
            board.find_or_create_images_from_word_list(words)
          }.to change(Image, :count).by(3)
          expect(board.images.pluck(:label)).to match_array(words)
        end
      end
    end

    context "when all words already exist" do
      before do
        FactoryBot.create(:image, label: "apple")
        FactoryBot.create(:image, label: "banana")
        FactoryBot.create(:image, label: "cherry")
      end

      it "does not create any new images" do
        words = ["apple", "banana", "cherry"]
        expect {
          board.find_or_create_images_from_word_list(words)
        }.not_to change(Image, :count)
        expect(board.images.pluck(:label)).to match_array(words)
      end
    end

    context "when words have different casing" do
      before do
        FactoryBot.create(:image, label: "Apple")
      end

      # The lookup is case-sensitive — "Apple" and "apple" are treated as different images.
      it "creates a new image for the differently-cased word" do
        words = ["apple", "banana", "cherry"]
        expect {
          board.find_or_create_images_from_word_list(words)
        }.to change(Image, :count).by(3)
      end
    end

    context "when words contain leading/trailing whitespace" do
      # The method does NOT currently strip whitespace — labels are stored as-is.
      # This documents actual behavior; stripping would be a future improvement.
      it "stores the labels with whitespace intact" do
        words = ["  apple  ", "banana", "  cherry"]
        expect {
          board.find_or_create_images_from_word_list(words)
        }.to change(Image, :count).by(3)
        expect(board.images.pluck(:label)).to include("  apple  ", "  cherry", "banana")
      end
    end
  end

  describe "#viewable_by?" do
    let(:owner)     { FactoryBot.create(:user) }
    let(:stranger)  { FactoryBot.create(:user) }
    let(:admin)     { FactoryBot.create(:admin_user) }

    context "when the board is published" do
      let(:board) { FactoryBot.create(:board, user: owner, published: true) }

      it "is viewable by anyone, including logged-out visitors" do
        expect(board.viewable_by?(nil)).to be(true)
        expect(board.viewable_by?(stranger)).to be(true)
        expect(board.viewable_by?(owner)).to be(true)
      end
    end

    context "when the board is private (unpublished)" do
      let(:board) { FactoryBot.create(:board, user: owner, published: false) }

      it "is not viewable by a logged-out visitor" do
        expect(board.viewable_by?(nil)).to be(false)
      end

      it "is not viewable by an unrelated user" do
        expect(board.viewable_by?(stranger)).to be(false)
      end

      it "is viewable by the owner" do
        expect(board.viewable_by?(owner)).to be(true)
      end

      it "is viewable by an admin" do
        expect(board.viewable_by?(admin)).to be(true)
      end

      it "is viewable by a team member the board is shared with" do
        team = FactoryBot.create(:team, created_by: owner)
        TeamBoard.create!(team: team, board: board)
        TeamUser.create!(team: team, user: stranger, role: "member")
        expect(board.reload.viewable_by?(stranger)).to be(true)
      end
    end
  end

  describe "#api_view" do
    let(:user) { FactoryBot.create(:user) }
    let(:board) do
      FactoryBot.create(:board, user: user, published: true, position: 3,
        data: { "current_word_list" => ["apple", "banana"] })
    end

    it "exposes published, position, and data from the board" do
      view = board.api_view(user)
      expect(view[:published]).to be(true)
      expect(view[:position]).to eq(3)
      expect(view[:data]).to eq("current_word_list" => ["apple", "banana"])
    end
  end

  describe "#add_image" do
    let(:user)  { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user, voice: "polly:kevin") }
    let(:image) { FactoryBot.create(:image, user: user) }

    # SaveAudioJob used to be enqueued twice per image: once explicitly here
    # and once by BoardImage's after_create callback. add_image now leaves
    # audio entirely to the callback.
    it "enqueues SaveAudioJob exactly once for the new board image" do
      expect { board.add_image(image.id) }
        .to change(SaveAudioJob.jobs, :size).by(1)
    end

    it "enqueues the audio job for the created board image and voice" do
      board_image = board.add_image(image.id)

      args = SaveAudioJob.jobs.last["args"]
      expect(args[1]).to eq("polly:kevin")
      expect(args[2]).to eq(board_image.id)
    end
  end

  describe "#display_image_url with display_follows_preview flag" do
    let(:user) { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user) }

    before do
      board.update_column(:display_image_url, "https://example.com/user-cover.png")
    end

    context "when the flag is off" do
      it "returns the stored column value" do
        expect(board.display_image_url).to eq("https://example.com/user-cover.png")
      end
    end

    context "when the flag is on but no preview is attached" do
      it "still returns the stored column value (no preview to resolve to)" do
        board.update!(settings: board.settings.merge("display_follows_preview" => true))
        expect(board.display_image_url).to eq("https://example.com/user-cover.png")
      end
    end

    context "when the flag is on and a preview is attached" do
      before do
        board.preview_image.attach(
          io: StringIO.new("png-bytes"),
          filename: "preview.png",
          content_type: "image/png",
        )
        board.update!(settings: board.settings.merge("display_follows_preview" => true))
      end

      it "returns the live preview URL" do
        expect(board.display_image_url).to eq(board.preview_image_url)
      end

      it "resolves to the new URL after the preview regenerates" do
        original_url = board.display_image_url
        board.preview_image.purge
        board.preview_image.attach(
          io: StringIO.new("new-png-bytes"),
          filename: "preview.png",
          content_type: "image/png",
        )

        expect(board.display_image_url).to eq(board.preview_image_url)
        expect(board.display_image_url).not_to eq(original_url) if board.preview_image_url != original_url
      end
    end
  end
end
