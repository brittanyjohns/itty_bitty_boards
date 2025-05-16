# == Schema Information
#
# Table name: messages
#
#  id                   :bigint           not null, primary key
#  subject              :string
#  body                 :text
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  sender_id            :integer
#  recipient_id         :integer
#  sent_at              :datetime
#  read_at              :datetime
#  sender_deleted_at    :datetime
#  recipient_deleted_at :datetime
#
class Message < ApplicationRecord
  belongs_to :sender, class_name: "User", foreign_key: "sender_id"
  belongs_to :recipient, class_name: "User", foreign_key: "recipient_id"
  has_many_attached :attachments

  validates :subject, presence: true
  validates :body, presence: true

  scope :sent_by_user, ->(user_id) { where(sender_id: user_id, sender_deleted_at: nil) }
  scope :received_by_user, ->(user_id) { where(recipient_id: user_id, recipient_deleted_at: nil) }
  scope :read, -> { where.not(read_at: nil) }
  scope :sent_or_received_by_user, ->(user_id) { where("sender_id = ? OR recipient_id = ?", user_id, user_id) }

  def self.search(query)
    where("subject LIKE ? OR body LIKE ?", "%#{query}%", "%#{query}%")
  end

  def self.filter_by_user(user_id)
    where("sender_id = ? OR recipient_id = ?", user_id, user_id)
  end

  def mark_as_deleted_by(user_id, user_type)
    @messages = []
    if sender_id == user_id
      user_type = "sender"
      self.update(sender_deleted_at: Time.current)
      @messages = recipient.received_messages.reload
    elsif recipient_id == user_id
      user_type = "recipient"
      self.update(recipient_deleted_at: Time.current)
      @messages = sender.sent_messages.reload
    else
      raise "User is neither sender nor recipient"
    end
    @messages
  end

  def mark_as_read
    update(read_at: Time.current)
  end

  def notify_recipient
    if recipient.should_receive_notifications?
      begin
        UserMailer.message_notification_email(self).deliver_now
      rescue Net::SMTPFatalError => e
        Rails.logger.error "Failed to send email: #{e.message}"
        puts "Failed to send email: #{e.message}"
      end
      recipient.set_recently_notified!
      puts "Notification sent to #{recipient.email} about new message from #{sender.email}"
    else
      puts "Notification not sent to #{recipient.email} because they have disabled notifications"
    end
  end

  def api_view(current_user = nil)
    current_user_id = current_user&.id
    {
      id: id,
      subject: subject,
      body: body,
      type: get_message_type(current_user_id),
      sender: { id: sender_id, name: sender.display_name, email: sender.email },
      recipient: { id: recipient_id, name: recipient.display_name, email: recipient.email },
      sent_at: sent_at,
      read_at: read_at,
      sender_deleted_at: sender_deleted_at,
      recipient_deleted_at: recipient_deleted_at,
      created_at: created_at,
      updated_at: updated_at,
    }
  end

  def get_message_type(current_user_id)
    if sender_id == current_user_id
      "sent"
    elsif recipient_id == current_user_id
      "received"
    else
      "unknown"
    end
  end

  def show_api_view(current_user)
    {
      id: id,
      subject: subject,
      body: body,
      sender: { id: sender_id, name: sender.display_name, email: sender.email },
      recipient: { id: recipient_id, name: recipient.display_name, email: recipient.email },
      sent_at: sent_at,
      read_at: read_at,
      sender_deleted_at: sender_deleted_at,
      recipient_deleted_at: recipient_deleted_at,
      attachments: attachments.map { |attachment| { url: Rails.application.routes.url_helpers.rails_blob_url(attachment, only_path: true) } },
      created_at: created_at,
      updated_at: updated_at,
    }
  end
end
