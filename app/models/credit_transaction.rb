# == Schema Information
#
# Table name: credit_transactions
#
#  id              :bigint           not null, primary key
#  user_id         :bigint           not null
#  amount          :integer          not null  # signed; + grants, - spends
#  kind            :string           not null  # plan_grant, topup_purchase, spend, expire, refund, admin_adjust, promo
#  source          :string           not null  # "plan" or "topup"
#  feature_key     :string                     # for spend rows
#  stripe_event_id :string                     # unique when present
#  stripe_price_id :string
#  expires_at      :datetime
#  metadata        :jsonb            not null, default {}
#  created_at      :datetime         not null
#
class CreditTransaction < ApplicationRecord
  belongs_to :user

  KINDS = %w[plan_grant topup_purchase spend expire refund admin_adjust promo].freeze
  SOURCES = %w[plan topup].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :source, inclusion: { in: SOURCES }
  validates :amount, presence: true
  validates :stripe_event_id, uniqueness: true, allow_nil: true

  scope :grants, -> { where(kind: %w[plan_grant topup_purchase admin_adjust promo refund]) }
  scope :spends, -> { where(kind: "spend") }
  scope :plan, -> { where(source: "plan") }
  scope :topup, -> { where(source: "topup") }
  scope :unexpired_plan_grants, -> { plan.where(kind: "plan_grant").where("expires_at IS NULL OR expires_at > ?", Time.current) }
end
