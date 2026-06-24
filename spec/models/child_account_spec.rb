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

  # A sandbox is a no-login demo account. It must never advertise a private
  # sign-in — neither via can_sign_in? nor a startup_url — even though its
  # owner may be on a paid plan or in their free trial. Regression guard for
  # the contradiction where a sandbox shipped can_sign_in: true + a real URL.
  describe "sandbox sign-in gating" do
    let(:paid_user) { FactoryBot.create(:user, plan_type: "pro") }

    it "denies can_sign_in? for a sandbox owned by a paid user" do
      sandbox = FactoryBot.create(:child_account, user: paid_user,
                                                   status: ChildAccount::SANDBOX)
      expect(paid_user.paid_plan?).to be(true)
      expect(sandbox.can_sign_in?).to be(false)
    end

    it "returns a nil startup_url for a sandbox" do
      sandbox = FactoryBot.create(:child_account, user: paid_user,
                                                   status: ChildAccount::SANDBOX)
      expect(sandbox.startup_url).to be_nil
    end

    it "denies can_sign_in? for a sandbox even when the owner is an admin" do
      admin   = FactoryBot.create(:admin_user)
      sandbox = FactoryBot.create(:child_account, user: admin,
                                                  status: ChildAccount::SANDBOX)
      expect(sandbox.can_sign_in?).to be(false)
    end

    it "still allows sign-in and a startup_url for an active communicator" do
      active = FactoryBot.create(:child_account, user: paid_user,
                                                 username: "signme",
                                                 status: ChildAccount::ACTIVE)
      expect(active.can_sign_in?).to be(true)
      expect(active.startup_url).to include("/accounts/sign-in?username=signme")
    end
  end

  # public_api_view backs unauthenticated public profile pages. Unlike the full
  # api_view, it must never leak parent email, passcode, claim tokens, or other
  # internal fields — only safe display data.
  describe "#public_api_view" do
    let(:account) { FactoryBot.create(:child_account, user: user, name: "Sunny") }

    it "exposes only the safe display keys" do
      expect(account.public_api_view.keys).to contain_exactly(:id, :name, :avatar_url, :voice, :boards)
    end

    it "does not leak any sensitive or internal fields" do
      view = account.public_api_view
      %i[parent_email passcode claim_token claim_url supporters supervisors
         settings details user_id authentication_token].each do |leaked|
        expect(view).not_to have_key(leaked)
      end
    end

    it "includes only favorited boards, with display-safe attributes" do
      fav_board = FactoryBot.create(:board, user: user, name: "Faves")
      favorited = FactoryBot.create(:child_board, child_account: account, board: fav_board, favorite: true)
      FactoryBot.create(:child_board, child_account: account,
                                      board: FactoryBot.create(:board, user: user),
                                      favorite: false)

      boards = account.public_api_view[:boards]
      expect(boards.map { |b| b[:id] }).to contain_exactly(favorited.id)
      expect(boards.first.keys).to contain_exactly(:id, :name, :board_type, :display_image_url)
    end
  end
end
