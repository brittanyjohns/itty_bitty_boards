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
    before_action :set_kit_page, only: %i[edit update publish unpublish]

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

    private

    def set_kit_page
      @kit_page = KitPage.find_by(id: params[:id])
      redirect_to admin_dashboard_kit_pages_path, alert: "Kit page not found." unless @kit_page
    end

    # Flat params, matching the rest of the admin (form_tag + *_tag helpers).
    def assign_and_save(page)
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

    helper_method :selectable_printables, :kit_preview_url

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

    def kit_preview_url(page)
      host = ENV["FRONT_END_URL"].presence || "https://app.speakanyway.com"
      "#{host.chomp("/")}/kit/#{page.slug}"
    end
  end
end
