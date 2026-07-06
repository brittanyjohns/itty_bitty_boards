module Marketing
  # Generic AAC "communication ID" backpack tag, compact and print-and-cut,
  # laid N-up on a Letter page. Fillable (no per-child data); the QR points at
  # the /classroom funnel. Distinct from the app's detailed Profile safety card
  # (Communicators::GenerateSafetyIdCard) — this is a small clip-on tag.
  class SafetyTagSheet
    include SheetRendering

    DEFAULT_PER_PAGE = 2 # two portrait tags side-by-side on Letter

    def initialize(qr_target_url: nil, per_page: DEFAULT_PER_PAGE)
      @qr_target_url = qr_target_url.presence
      @per_page = per_page.to_i.positive? ? per_page.to_i : DEFAULT_PER_PAGE
    end

    def to_pdf
      render_letter_pdf(
        template: "marketing/safety_tag_sheet",
        assigns: {
          card_count: @per_page,
          logo: logo_base64,
          qr_data_url: qr_data_url(@qr_target_url),
        },
      )
    end
  end
end
