# == Schema Information
#
# Table name: profiles
#
#  id               :bigint           not null, primary key
#  profileable_type :string
#  profileable_id   :bigint
#  username         :string
#  slug             :string
#  bio              :text
#  intro            :string
#  settings         :jsonb
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  placeholder      :boolean          default(FALSE)
#  claim_token      :string
#  claimed_at       :datetime
#  sku              :string
#  profile_kind     :string           default("safety"), not null
#  allow_discovery  :boolean          default(FALSE), not null
#
# app/models/page.rb
class Page < Profile
  def headline
    public_settings(kind: :public)["headline"]
  end
end
