module API
  # Public (no-auth) capture endpoint for anonymous free-board-download leads.
  # An unsigned-in visitor enters their email to download a board PDF; the email
  # becomes a Mailchimp marketing lead (synced async via MailchimpUpsertLeadJob).
  class DownloadLeadsController < API::ApplicationController
    skip_before_action :authenticate_token!, only: %i[create]

    def create
      lead = DownloadLead.new(download_lead_params)

      if lead.save
        MailchimpUpsertLeadJob.perform_async(lead.id)
        render json: { success: true }, status: :created
      else
        render json: { success: false, errors: lead.errors.full_messages }, status: :unprocessable_content
      end
    end

    private

    def download_lead_params
      params.require(:download_lead).permit(:email, :name, :board_id, :source, data: {})
    end
  end
end
