# == Schema Information
#
# Table name: users
#
#  id                              :bigint           not null, primary key
#  email                           :string           default(""), not null
#  encrypted_password              :string           default(""), not null
#  reset_password_token            :string
#  reset_password_sent_at          :datetime
#  remember_created_at             :datetime
#  sign_in_count                   :integer          default(0), not null
#  current_sign_in_at              :datetime
#  last_sign_in_at                 :datetime
#  current_sign_in_ip              :string
#  last_sign_in_ip                 :string
#  name                            :string
#  role                            :string
#  created_at                      :datetime         not null
#  updated_at                      :datetime         not null
#  tokens                          :integer          default(0)
#  stripe_customer_id              :string
#  authentication_token            :string
#  jti                             :string           not null
#  invitation_token                :string
#  invitation_created_at           :datetime
#  invitation_sent_at              :datetime
#  invitation_accepted_at          :datetime
#  invitation_limit                :integer
#  invited_by_id                   :integer
#  invited_by_type                 :string
#  current_team_id                 :bigint
#  play_demo                       :boolean          default(TRUE)
#  settings                        :jsonb
#  base_words                      :string           default([]), is an Array
#  plan_type                       :string           default("free")
#  plan_expires_at                 :datetime
#  plan_status                     :string           default("active")
#  monthly_price                   :decimal(8, 2)    default(0.0)
#  yearly_price                    :decimal(8, 2)    default(0.0)
#  total_plan_cost                 :decimal(8, 2)    default(0.0)
#  uuid                            :uuid
#  child_lookup_key                :string
#  locked                          :boolean          default(FALSE)
#  organization_id                 :bigint
#  vendor_id                       :bigint
#  stripe_subscription_id          :string
#  temp_login_token                :string
#  temp_login_expires_at           :datetime
#  force_password_reset            :boolean          default(FALSE)
#  paid_plan_type                  :string
#  delete_account_token            :string
#  delete_account_token_expires_at :datetime
#  deleted_at                      :datetime
#  layout                          :jsonb
#  confirmation_token              :string
#  confirmed_at                    :datetime
#  confirmation_sent_at            :datetime
#  unconfirmed_email               :string
#
require "rails_helper"

RSpec.describe User, type: :model do
  after(:all) do
    Team.destroy_all
    User.destroy_all
  end
  context "validation" do
    subject(:user) { FactoryBot.build(:user) }
    it "is invalid without a email" do
      user.email = nil
      expect(user.save).to be_falsey
    end

    it "is valid with name and email" do
      user.name = "Some name"
      user.email = "email@test.com"
      expect(user.save).to be_truthy
    end
  end
  context "plan_type checks" do
    it "defaults to basic plan (soft trial) on signup" do
      user = FactoryBot.create(:user)
      expect(user.plan_type).to eq("basic")
    end

    it "does not override an explicitly set plan_type on create" do
      user = FactoryBot.create(:user, plan_type: "pro")
      expect(user.plan_type).to eq("pro")
    end

    it "does not change plan_type on subsequent saves" do
      user = FactoryBot.create(:user)
      user.update!(name: "Updated")
      expect(user.plan_type).to eq("basic")
    end

    it "recognizes pro plan" do
      user = FactoryBot.create(:user, plan_type: "pro")
      expect(user.pro?).to be true
      expect(user.free?).to be false
    end

    it "recognizes basic plan" do
      user = FactoryBot.create(:user, plan_type: "basic")
      expect(user.basic?).to be true
    end

    it "premium? returns false for free plan" do
      user = FactoryBot.create(:user, plan_type: "free")
      expect(user.premium?).to be false
    end

    it "premium? returns true when plan_type includes 'premium'" do
      user = FactoryBot.create(:user, plan_type: "premium")
      expect(user.premium?).to be true
    end
  end

  context "monthly_limit_for" do
    it "returns a high limit for admin users" do
      admin = FactoryBot.create(:user, role: "admin")
      expect(admin.monthly_limit_for("image_generation")).to eq(10000)
    end

    it "returns a lower limit for free users" do
      user = FactoryBot.create(:user, plan_type: "free")
      limit = user.monthly_limit_for("image_generation")
      expect(limit).to be <= 5
    end

    it "returns a higher limit for pro users than free users" do
      free_user = FactoryBot.create(:user, plan_type: "free")
      pro_user  = FactoryBot.create(:user, plan_type: "pro")
      expect(pro_user.monthly_limit_for("image_generation")).to be >
        free_user.monthly_limit_for("image_generation")
    end
  end

  context "invite_new_user_to_team!" do
    let(:current_user) { FactoryBot.create(:user) }

    let(:user_to_invite_email) { "user@email.com" }
    let(:team) { FactoryBot.create(:team) }

    subject(:invite_new_user_to_team!) do
      # current_user.invite_new_user_to_team!(user_to_invite_email, team)
      @user = User.create_from_email(user_to_invite_email, nil, current_user.id)
      team.add_member!(@user) if @user
    end
    before do
      # Create a team and add the current user to it
      team.add_member!(current_user, "admin")
    end
    it "adds the invited user to the team" do
      subject
      expect(team.users.count).to eq(2)
      expect(team.users.last.email).to eq(user_to_invite_email)
    end

    it "sets the invited_by_id for the invited user" do
      subject
      invited_user = User.find_by(email: user_to_invite_email)
      expect(invited_user).not_to be_nil
      expect(invited_user.invited_by_id).to eq(current_user.id)
    end

    it "sends an invitation email to the invited user" do
      expect { subject }.to change { ActionMailer::Base.deliveries.count }.by(1)
      last_email = ActionMailer::Base.deliveries.last
      expect(last_email.to).to include(user_to_invite_email)
      expect(last_email.subject).to include("You have been invited to join SpeakAnyWay AAC!")
    end
  end
end
