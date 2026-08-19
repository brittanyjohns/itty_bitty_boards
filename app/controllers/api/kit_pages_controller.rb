module API
  # Public (no-auth) surface behind app.speakanyway.com/kit/:slug — a reusable
  # lead-magnet landing page whose copy and download live in the database.
  #
  # #show never carries a file URL. The URL is revealed only by #download, and
  # only after an email has been captured as a DownloadLead. That gate is soft
  # by design (the underlying S3 objects are public), and matches what
  # /classroom already does — see KitPage's header.
  class KitPagesController < API::ApplicationController
    skip_before_action :authenticate_token!, only: %i[show download]

    before_action :set_kit_page

    def show
      render json: @kit_page.public_view
    end

    def download
      # `downloadable: false` in #show already tells the frontend to hide the
      # form; this answers the race where a printable is swapped out between
      # page load and submit.
      unless @kit_page.downloadable?
        return render json: { error: "not_available" }, status: :unprocessable_content
      end

      lead = DownloadLead.new(
        email: params[:email],
        name: params[:name],
        source: @kit_page.lead_source,
        data: lead_data,
      )

      unless lead.save
        return render json: { success: false, errors: lead.errors.full_messages },
                      status: :unprocessable_content
      end

      enqueue_or_skip_mailchimp(lead)
      render json: { files: @kit_page.download_files }
    end

    private

    # Unpublished and unknown are the same answer on purpose: a draft page's
    # existence isn't public information.
    def set_kit_page
      @kit_page = KitPage.published.find_by(slug: params[:slug])
      return if @kit_page

      render json: { error: "kit_page_not_found" }, status: :not_found
    end

    # UTM/campaign metadata, same free-form jsonb /classroom sends, stamped
    # with the slug so a lead is traceable to its page even if the source
    # naming convention ever changes.
    def lead_data
      submitted = params.permit(data: {}).to_h["data"] || {}
      submitted.merge("kit_slug" => @kit_page.slug)
    end

    # Mirrors API::DownloadLeadsController: consent is asked once, in the
    # model, so a lead that never opted in is marked "skipped" rather than
    # sitting in mailchimp_pending forever.
    def enqueue_or_skip_mailchimp(lead)
      if lead.sync_to_mailchimp?
        MailchimpUpsertLeadJob.perform_async(lead.id)
      else
        lead.update_column(:mailchimp_status, DownloadLead::MAILCHIMP_SKIPPED)
      end
    end
  end
end
