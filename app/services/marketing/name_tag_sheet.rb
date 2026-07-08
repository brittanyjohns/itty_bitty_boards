module Marketing
  # Renders the generic AAC Classroom name-tag sheet (variant A from
  # .claude-notes/name-tag-asset-sketch.md): a fillable "Hi! My name is ___"
  # card, N-up on a Letter page, with a shared QR pointing at the marketing
  # funnel. No Profile / no per-child data — it is a blank classroom printable.
  #
  # HTML -> PDF via Grover, same engine as the board and communicator-asset
  # generators. Returns PDF bytes; the caller streams or hosts them. QR
  # rendering + logo + Letter Grover options come from SheetRendering, so the
  # ECC level and print resolution stay in one place across all three tags.
  class NameTagSheet
    include SheetRendering

    DEFAULT_PER_PAGE = 8 # 2 columns x 4 rows on Letter portrait

    def initialize(qr_target_url: nil, per_page: DEFAULT_PER_PAGE)
      @qr_target_url = qr_target_url.presence
      @per_page = per_page.to_i.positive? ? per_page.to_i : DEFAULT_PER_PAGE
    end

    def to_pdf
      render_letter_pdf(
        template: "marketing/name_tag_sheet",
        assigns: {
          card_count: @per_page,
          logo: logo_base64,
          qr_data_url: qr_data_url(@qr_target_url),
        },
      )
    end
  end
end
