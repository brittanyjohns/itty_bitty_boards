# == Schema Information
#
# Table name: child_accounts
#
#  id                     :bigint           not null, primary key
#  username               :string           default(""), not null
#  name                   :string           default("")
#  encrypted_password     :string           default(""), not null
#  reset_password_token   :string
#  reset_password_sent_at :datetime
#  remember_created_at    :datetime
#  sign_in_count          :integer          default(0), not null
#  current_sign_in_at     :datetime
#  last_sign_in_at        :datetime
#  current_sign_in_ip     :string
#  user_id                :bigint
#  authentication_token   :string
#  settings               :jsonb
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#
require "rails_helper"

RSpec.describe ChildAccount, type: :model do
  let(:user) { FactoryBot.create(:user) }

  describe "validations" do
    it "auto-generates a username when none is given (set_username_if_missing callback)" do
      account = FactoryBot.build(:child_account, username: nil, user: user)
      expect(account).to be_valid
      expect(account.username).to be_present
    end

    it "is valid with an explicit username and user" do
      account = FactoryBot.build(:child_account, username: "myaccount", user: user)
      expect(account).to be_valid
    end

    it "requires a unique username" do
      FactoryBot.create(:child_account, username: "duplicatename", user: user)
      duplicate = FactoryBot.build(:child_account, username: "duplicatename", user: user)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:username]).to be_present
    end
  end

  describe "associations" do
    it "belongs to a user (optional)" do
      account = FactoryBot.create(:child_account, user: user)
      expect(account.user).to eq(user)
    end

    it "can have many child_boards" do
      account = FactoryBot.create(:child_account, user: user)
      board   = FactoryBot.create(:board, user: user)
      FactoryBot.create(:child_board, child_account: account, board: board)
      expect(account.child_boards.count).to eq(1)
    end
  end

  describe "#favorite_boards" do
    it "returns favorited boards for a Free-tier user (MySpeak quick-comm board is not plan-gated)" do
      free_user = FactoryBot.create(:user)
      free_user.update_column(:plan_type, "free") # new users get a soft Basic trial; force genuine Free
      account   = FactoryBot.create(:child_account, user: free_user)
      fav_board = FactoryBot.create(:board, user: free_user)
      favorited = FactoryBot.create(:child_board, child_account: account, board: fav_board, favorite: true)
      FactoryBot.create(:child_board, child_account: account,
                                      board: FactoryBot.create(:board, user: free_user),
                                      favorite: false)

      expect(free_user.paid_plan?).to be(false)
      expect(account.favorite_boards).to contain_exactly(favorited)
    end
  end

  describe "authentication_token" do
    it "is generated automatically on create" do
      account = FactoryBot.create(:child_account, user: user)
      expect(account.authentication_token).to be_present
    end

    it "can be regenerated via reset_authentication_token!" do
      account   = FactoryBot.create(:child_account, user: user)
      old_token = account.authentication_token
      account.reset_authentication_token!
      expect(account.authentication_token).not_to eq(old_token)
    end
  end
end
