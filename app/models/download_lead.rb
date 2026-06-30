# A DownloadLead is captured when an anonymous (not-signed-in) visitor enters
# their email to download a free board PDF. The email is synced to Mailchimp as
# a marketing lead (see MailchimpUpsertLeadJob). board_id is a soft reference
# (belongs_to optional, no DB FK) so a lead survives the board being deleted.
class DownloadLead < ApplicationRecord
  # Default capture source when the client doesn't send one.
  DEFAULT_SOURCE = "free_download".freeze

  belongs_to :board, optional: true

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }

  before_validation :default_source

  scope :for_source, ->(source) { where(source: source) }

  private

  def default_source
    self.source = DEFAULT_SOURCE if source.blank?
  end
end
