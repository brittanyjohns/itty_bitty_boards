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
#
class UserSerializer
  include JSONAPI::Serializer
  attributes :id, :email, :created_at
end
