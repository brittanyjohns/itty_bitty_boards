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
      # `preview` is merged in by the controller rather than published by
      # #public_view, so a live page's payload is byte-for-byte what it was.
      payload = @kit_page.public_view
      payload = payload.merge(preview: true) if preview?

      render json: payload
    end

    def download
      # `downloadable: false` with no `templates` in #show already tells the
      # frontend to hide the form; this answers the race where a printable is
      # swapped out between page load and submit.
      unless @kit_page.offers_anything?
        return render json: { error: "not_available" }, status: :unprocessable_content
      end

      # A preview never writes a lead. The admin checking their own draft would
      # otherwise put a fake `kit_<slug>` row in the leads table and fire a
      # Mailchimp upsert for themselves — so previewing the page would corrupt
      # the numbers the page exists to produce.
      return render(json: handover_payload) if preview?

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
      render json: handover_payload
    end

    private

    # Everything the email bought. `files` stays present — as `[]` on a
    # templates-only page — so a frontend that predates templates renders its
    # existing "nothing to download" dead end rather than throwing.
    #
    # `images` is the WHOLE gallery, gated pages and already-public ones alike,
    # because the frontend swaps the list wholesale and a public picture must
    # keep its position in it. It is never a reason to open the gate: a page
    # with pictures and nothing to hand over is still a dead end, which is why
    # #download gates on `offers_anything?` and not on this.
    def handover_payload
      {
        files: @kit_page.download_files,
        templates: @kit_page.template_links,
        images: @kit_page.released_gallery_images,
      }
    end

    # Unpublished and unknown are the same answer on purpose: a draft page's
    # existence isn't public information. A valid preview token is the one way
    # past that, and an INVALID one is answered identically — a wrong guess must
    # not become a way to probe for drafts.
    def set_kit_page
      @kit_page = KitPage.for_public(params[:slug], preview_token: params[:preview])
      return if @kit_page

      render json: { error: "kit_page_not_found" }, status: :not_found
    end

    # Only ever true for a page that needed the token to be visible at all. A
    # token passed to a LIVE page changes nothing: it is already public, and a
    # real visitor who copied a preview link must still be counted as a lead.
    def preview?
      return false if @kit_page.nil? || @kit_page.published?

      params[:preview].present?
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
