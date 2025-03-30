# == Schema Information
#
# Table name: contest_entries
#
#  id         :bigint           not null, primary key
#  name       :string
#  email      :string
#  data       :jsonb
#  event_id   :bigint           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class ContestEntry < ApplicationRecord
  belongs_to :event

  validates :name, presence: true
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email, uniqueness: { scope: :event_id, message: "has already entered this event" }

  def api_view
    {
      id: id,
      name: name,
      email: email,
      data: data,
      event_id: event_id,
      created_at: created_at,
      updated_at: updated_at,
    }
  end
end
