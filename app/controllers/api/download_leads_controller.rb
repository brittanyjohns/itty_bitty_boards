module API
  # Public (no-auth) capture endpoint for anonymous free-board-download leads.
  # An unsigned-in visitor enters their email to download a board PDF; the email
  # becomes a Mailchimp marketing lead (synced async via MailchimpUpsertLeadJob).
  #
  # Also carries Words Within Reach playground nominations (source
  # "playground_nomination"), which are the same shape of anonymous, email-keyed
  # capture. Those only sync to Mailchimp when the nominator explicitly opted in
  # — see DownloadLead#sync_to_mailchimp?.
  class DownloadLeadsController < API::ApplicationController
    skip_before_action :authenticate_token!, only: %i[create]

    def create
      lead = DownloadLead.new(download_lead_params)

      if lead.save
        enqueue_or_skip_mailchimp(lead)
        render json: { success: true }, status: :created
      else
        render json: { success: false, errors: lead.errors.full_messages }, status: :unprocessable_content
      end
    end

    private

    # A lead with no marketing consent is marked "skipped" rather than left at
    # "pending", so it doesn't linger in the mailchimp_pending scope and read as
    # a stuck sync.
    def enqueue_or_skip_mailchimp(lead)
      if lead.sync_to_mailchimp?
        MailchimpUpsertLeadJob.perform_async(lead.id)
      else
        lead.update_column(:mailchimp_status, DownloadLead::MAILCHIMP_SKIPPED)
      end
    end

    def download_lead_params
      params.require(:download_lead).permit(:email, :name, :board_id, :source, data: {})
    end
  end
end
