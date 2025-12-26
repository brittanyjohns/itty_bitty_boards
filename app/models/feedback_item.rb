# == Schema Information
#
# Table name: feedback_items
#
#  id            :bigint           not null, primary key
#  user_id       :bigint           not null
#  feedback_type :string           not null
#  role          :string           not null
#  subject       :string
#  message       :text             not null
#  page_url      :string
#  app_version   :string
#  platform      :string
#  device        :string
#  allow_contact :boolean          default(TRUE), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
class FeedbackItem < ApplicationRecord
  belongs_to :user

  FEEDBACK_TYPES = %w[bug feature question praise].freeze

  validates :feedback_type, inclusion: { in: FEEDBACK_TYPES }
  validates :message, presence: true

  after_create :send_admin_notification

  def api_view
    {
      id: id,
      feedback_type: feedback_type,
      subject: subject,
      message: message,
      page_url: page_url,
      app_version: app_version,
      platform: platform,
      device: device,
      allow_contact: allow_contact,
      role: role,
      user: {
        id: user.id,
        name: user.name,
        email: user.email,
      },
      created_at: created_at,
      updated_at: updated_at,
    }
  end

  def email
    "#{user.name} <#{user.email}>"
  end

  def name
    user.name
  end

  private

  def send_admin_notification
    AdminMailer.new_feedback_email(self).deliver_now
  end
end
