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
#
require "rails_helper"

RSpec.describe Board, type: :model do
  context "validation" do
    let(:user) { FactoryBot.create(:user) }
    subject(:board) { FactoryBot.build(:board, name: nil, user: user) }
    it "is invalid without a name" do
      puts "board: #{board.inspect}"
      expect(board.save).to be_falsey
    end

    it "is valid with user and name" do
      board.name = "Some name"
      expect(board.save!).to be_truthy
    end
  end
end
