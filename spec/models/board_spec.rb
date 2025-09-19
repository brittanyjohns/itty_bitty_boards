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
#  language              :string           default("en")
#  board_images_count    :integer          default(0), not null
#  published             :boolean          default(FALSE)
#  favorite              :boolean          default(FALSE)
#  vendor_id             :bigint
#  slug                  :string           default("")
#  in_use                :boolean          default(FALSE), not null
#  is_template           :boolean          default(FALSE), not null
#
require "rails_helper"

RSpec.describe Board, type: :model do
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

      it "treats words case-insensitively" do
        words = ["apple", "banana", "cherry"]
        expect {
          board.find_or_create_images_from_word_list(words)
        }.to change(Image, :count).by(2)
        expect(board.images.pluck(:label)).to match_array(words)
      end
    end

    context "when words contain leading/trailing whitespace" do
      it "strips whitespace before processing" do
        words = ["  apple  ", "banana", "  cherry"]
        expect {
          board.find_or_create_images_from_word_list(words)
        }.to change(Image, :count).by(3)
        expect(board.images.pluck(:label)).to match_array(["apple", "banana", "cherry"])
      end
    end
  end
end
