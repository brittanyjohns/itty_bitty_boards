# == Schema Information
#
# Table name: users
#
#  id                     :bigint           not null, primary key
#  email                  :string           default(""), not null
#  encrypted_password     :string           default(""), not null
#  reset_password_token   :string
#  reset_password_sent_at :datetime
#  remember_created_at    :datetime
#  sign_in_count          :integer          default(0), not null
#  current_sign_in_at     :datetime
#  last_sign_in_at        :datetime
#  current_sign_in_ip     :string
#  last_sign_in_ip        :string
#  name                   :string
#  role                   :string
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  tokens                 :integer          default(0)
#  stripe_customer_id     :string
#  authentication_token   :string
#  jti                    :string           not null
#  invitation_token       :string
#  invitation_created_at  :datetime
#  invitation_sent_at     :datetime
#  invitation_accepted_at :datetime
#  invitation_limit       :integer
#  invited_by_id          :integer
#  invited_by_type        :string
#  current_team_id        :bigint
#  play_demo              :boolean          default(TRUE)
#  settings               :jsonb
#  base_words             :string           default([]), is an Array
#  plan_type              :string           default("free")
#  plan_expires_at        :datetime
#  plan_status            :string           default("active")
#  monthly_price          :decimal(8, 2)    default(0.0)
#  yearly_price           :decimal(8, 2)    default(0.0)
#  total_plan_cost        :decimal(8, 2)    default(0.0)
#  uuid                   :uuid
#  child_lookup_key       :string
#  locked                 :boolean          default(FALSE)
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
