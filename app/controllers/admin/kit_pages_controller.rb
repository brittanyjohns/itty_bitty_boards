module Admin
  # CRUD for the /kit/:slug landing pages. The point of the screen is that a new
  # lead-magnet page — copy, download, and Mailchimp tag — ships without a
  # deploy on either side.
  #
  # One rail is load-bearing: picking a printable that is SOLD on Etsy is
  # refused until it is confirmed a second time. Giving away a product that is
  # listed for sale should never be one mis-clicked dropdown row away, so the
  # confirmation is an explicit checkbox and it is stamped on the record with
  # who did it and when.
  class KitPagesController < Admin::ApplicationController
    before_action :set_kit_page,
                  only: %i[edit update publish unpublish upload_document remove_document regenerate_previews]

    def index
      @kit_pages = KitPage.includes(board_printable: :board).order(created_at: :desc)
    end

    def new
      @kit_page = KitPage.new(printable_variant: BoardPrintable::VARIANT_COLOR)
    end

    def create
      @kit_page = KitPage.new
      return render(:new, status: :unprocessable_entity) unless assign_and_save(@kit_page)

      redirect_to edit_admin_dashboard_kit_page_path(@kit_page),
                  notice: "Created “#{@kit_page.title}”#{@kit_page.published? ? " — it is live now." : " as a draft."}"
    end

    def edit; end

    def update
      return render(:edit, status: :unprocessable_entity) unless assign_and_save(@kit_page)

      redirect_to edit_admin_dashboard_kit_page_path(@kit_page), notice: "Saved “#{@kit_page.title}”."
    end

    def publish
      @kit_page.update!(published: true)
      redirect_to admin_dashboard_kit_pages_path, notice: "“#{@kit_page.title}” is live at /kit/#{@kit_page.slug}."
    end

    def unpublish
      @kit_page.update!(published: false)
      redirect_to admin_dashboard_kit_pages_path, notice: "“#{@kit_page.title}” is no longer public."
    end

    # Writes the page from the printable it gives away, so launching a campaign
    # is a dropdown and a button rather than an afternoon of copywriting.
    #
    # Populates the form and NOTHING ELSE — it never saves, so a suggestion that
    # reads badly is discarded by navigating away. Because it answers with a
    # rendered 200 rather than a redirect, the form carries `data-turbo="false"`;
    # without it Turbo Drive refuses the response and the button does nothing.
    def autofill
      @kit_page = params[:id].present? ? KitPage.find_by(id: params[:id]) : KitPage.new
      return redirect_to(admin_dashboard_kit_pages_path, alert: "Kit page not found.") unless @kit_page

      assign_form_attributes(@kit_page)
      @content_raw = params[:content].to_s.strip

      @error = apply_autofill(@kit_page)
      return render_form(status: :unprocessable_entity) if @error

      flash.now[:notice] = autofill_notice
      render_form
    end

    # Attaches a PDF that becomes this page's download in place of a printable.
    #
    # Its own form, posting here, rather than a file field in the main form:
    # "Autofill the page" re-renders that form, and a browser cannot repopulate
    # a file input across a render, so a file picked there would silently
    # vanish. Same shape as the listing-video upload on board printables.
    def upload_document
      upload = params[:document]

      if (error = document_error(upload))
        return redirect_to(edit_admin_dashboard_kit_page_path(@kit_page), alert: error)
      end

      @kit_page.attach_document!(
        io: upload,
        filename: upload.original_filename,
        label: params[:label].to_s.strip.presence,
      )
      enqueue_previews

      redirect_to edit_admin_dashboard_kit_page_path(@kit_page),
                  notice: "Uploaded “#{upload.original_filename}”. It is this page's download now."
    end

    # Purges one document. The previews are rebuilt from whatever is left —
    # they picture the FIRST document, so removing it must not leave the old
    # pages sitting above a different file.
    def remove_document
      document = find_document(params[:signed_id])
      unless document
        return redirect_to(edit_admin_dashboard_kit_page_path(@kit_page), alert: "That file isn't on this page.")
      end

      filename = document.filename.to_s
      document.purge
      @kit_page.documents.reset
      enqueue_previews

      redirect_to edit_admin_dashboard_kit_page_path(@kit_page), notice: "Removed “#{filename}”."
    end

    def regenerate_previews
      unless KitPages::DocumentPreviewRenderer.available?
        return redirect_to(edit_admin_dashboard_kit_page_path(@kit_page),
                           alert: "This host can't render PDF previews, so there's nothing to regenerate.")
      end

      enqueue_previews
      redirect_to edit_admin_dashboard_kit_page_path(@kit_page),
                  notice: "Rendering the previews… refresh in a moment to see them."
    end

    private

    # Sidekiq pushes to Redis immediately and the worker reads on its own
    # connection, so a job naming a row must not be enqueued from inside the
    # transaction that writes it. A no-op outside a transaction.
    def enqueue_previews
      page_id = @kit_page.id
      ActiveRecord.after_all_transactions_commit { RenderKitPreviewsJob.perform_async(page_id) }
    end

    def find_document(signed_id)
      return nil if signed_id.blank?

      @kit_page.documents.find { |file| file.signed_id == signed_id }
    end

    # Validated here rather than trusted, and reported as a flash rather than a
    # 422 — this is a small side form, so re-rendering the whole edit screen
    # around it would lose anything typed in the main one.
    def document_error(upload)
      return "Choose a PDF to upload." if upload.blank? || !upload.respond_to?(:read)

      unless KitPage::DOCUMENT_CONTENT_TYPES.include?(upload.content_type)
        return "That file is #{upload.content_type.presence || "an unknown type"}; upload a PDF."
      end

      if upload.size > KitPage::MAX_DOCUMENT_BYTES
        return "That file is #{ActiveSupport::NumberHelper.number_to_human_size(upload.size)}; " \
               "the cap is #{ActiveSupport::NumberHelper.number_to_human_size(KitPage::MAX_DOCUMENT_BYTES)}."
      end

      if @kit_page.ordered_documents.size >= KitPage::MAX_DOCUMENTS
        return "This page already has #{KitPage::MAX_DOCUMENTS} documents. Remove one first."
      end

      nil
    end

    # `new` posts to the collection route, `edit` to the member one.
    def autofill_path(page)
      if page.persisted?
        autofill_admin_dashboard_kit_page_path(page)
      else
        autofill_admin_dashboard_kit_pages_path
      end
    end

    def render_form(status: :ok)
      render(@kit_page.persisted? ? :edit : :new, status: status)
    end

    # Only the blanks are filled — anything already typed survives, including a
    # hand-written content blob. Returns an error string, or nil on success.
    def apply_autofill(page)
      copy = KitPages::CopySuggester.new(
        slug: page.slug, title: page.title, printable: page.board_printable,
      ).call

      page.slug = page.slug.presence || derived_slug(page)
      page.title = page.title.presence || copy[:title]
      page.eyebrow = page.eyebrow.presence || copy[:eyebrow]
      page.subhead = page.subhead.presence || copy[:subhead]
      page.cta_label = page.cta_label.presence || copy.dig(:closing, "cta_label")
      page.cta_path = page.cta_path.presence || copy.dig(:closing, "cta_path")

      # mailchimp_tag is left alone on purpose: `resolved_mailchimp_tag` already
      # derives one from the slug, so filling it in would only freeze a value
      # that currently follows a slug correction.
      fill_content(page, copy)
      nil
    rescue KitPages::CopySuggester::GenerationError => e
      "Couldn't write the copy: #{e.message}"
    end

    def fill_content(page, copy)
      @content_filled = false
      return if @content_raw.present?

      content = {}
      content["items"] = copy[:items] if copy[:items].any?
      content["closing"] = copy[:closing] if copy[:closing].present?
      return if content.empty?

      page.content = content
      @content_raw = JSON.pretty_generate(content)
      @content_filled = true
    end

    def autofill_notice
      if @content_filled
        "Filled in what was blank — read it over, then save."
      else
        "Filled in what was blank. Left the content JSON alone — clear it and autofill again to rewrite it."
      end
    end

    # Derived from the board's name, and only ever into a BLANK field: the slug
    # is the /kit/<slug> URL a campaign link points at, so re-deriving one that
    # already exists would move a live page.
    def derived_slug(page)
      base = page.board_printable&.board&.name.to_s.parameterize.first(60)
      return nil if base.blank?

      candidate = base
      suffix = 1
      while KitPage.where(slug: candidate).where.not(id: page.id).exists?
        suffix += 1
        candidate = "#{base}-#{suffix}"
      end
      candidate
    end

    def set_kit_page
      @kit_page = KitPage.find_by(id: params[:id])
      redirect_to admin_dashboard_kit_pages_path, alert: "Kit page not found." unless @kit_page
    end

    # Flat params, matching the rest of the admin (form_tag + *_tag helpers).
    # Split out of the save so `autofill` can rebuild the whole form from what
    # was submitted without persisting any of it.
    def assign_form_attributes(page)
      page.assign_attributes(
        slug: params[:slug].to_s.strip,
        title: params[:title].to_s.strip,
        eyebrow: params[:eyebrow].to_s.strip.presence,
        subhead: params[:subhead].to_s.strip.presence,
        board_printable_id: params[:board_printable_id].presence,
        printable_variant: params[:printable_variant].presence || BoardPrintable::VARIANT_COLOR,
        mailchimp_tag: params[:mailchimp_tag].to_s.strip.presence,
        cta_label: params[:cta_label].to_s.strip.presence,
        cta_path: params[:cta_path].to_s.strip.presence,
        published: ActiveModel::Type::Boolean.new.cast(params[:published]) || false,
      )
    end

    def assign_and_save(page)
      assign_form_attributes(page)

      return false unless assign_content(page)
      return false unless resolve_etsy_override(page)

      page.save
    end

    # The content blob is edited as raw JSON in v1. A parse failure re-renders
    # the form with what was typed, not with the last saved value.
    def assign_content(page)
      raw = params[:content].to_s.strip
      @content_raw = raw

      if raw.blank?
        page.content = {}
        return true
      end

      parsed = JSON.parse(raw)
      unless parsed.is_a?(Hash)
        @error = "Content must be a JSON object — it starts with { and ends with }."
        return false
      end

      page.content = parsed
      true
    rescue JSON::ParserError => e
      @error = "Content isn't valid JSON: #{e.message.truncate(160)}"
      false
    end

    # Refuses the save when the chosen printable is sold on Etsy and the admin
    # hasn't confirmed. An override already stamped on the record stands only
    # for the printable it was stamped for — swapping in a different protected
    # printable asks again.
    def resolve_etsy_override(page)
      unless page.gives_away_protected_printable?
        # The selection is no longer protected, so a stale stamp must not sit
        # there authorizing the next swap.
        page.etsy_override_at = nil
        page.etsy_override_by = nil
        return true
      end

      if override_confirmed?
        page.etsy_override_at = Time.current
        page.etsy_override_by = current_user
        return true
      end

      return true if page.etsy_override? && !page.board_printable_id_changed?

      @error = "“#{page.board_printable.board&.name}” is published on Etsy — printed copies of it are " \
               "sold. Tick “Give this away for free anyway” below if you really mean to hand it out free."
      false
    end

    def override_confirmed?
      ActiveModel::Type::Boolean.new.cast(params[:etsy_override]) || false
    end

    helper_method :selectable_printables, :kit_preview_url, :autofill_path, :preview_renderer_available?

    # Whether this host's libvips can rasterize a PDF. The Document card says so
    # plainly when it can't — a page that silently shows no pictures reads as a
    # broken upload.
    def preview_renderer_available? = KitPages::DocumentPreviewRenderer.available?

    # Only printables an admin could actually hand to a visitor: finished, and
    # carrying at least one PDF (a printable holding only listing images would
    # render a download form that can never deliver).
    def selectable_printables
      @selectable_printables ||= BoardPrintable
        .where(status: "complete")
        .includes(:board)
        .with_attached_files
        .order(created_at: :desc)
        .select { |printable| printable.pdf_files.any? }
    end

    # A draft carries a signed token so the Preview link actually opens the page
    # rather than the frontend's "This page isn't available". A LIVE page's link
    # stays clean — it is already public, and a URL an admin might paste into a
    # campaign must not carry a token.
    def kit_preview_url(page)
      host = ENV["FRONT_END_URL"].presence || "https://app.speakanyway.com"
      url = "#{host.chomp("/")}/kit/#{page.slug}"
      return url if page.published? || !page.persisted?

      "#{url}?preview=#{CGI.escape(page.preview_token)}"
    end
  end
end
