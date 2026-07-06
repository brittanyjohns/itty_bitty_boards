module Marketing
  # Generic AAC device tag ("This device is my voice"), compact and
  # print-and-cut, laid N-up on a Letter page. No per-child data; the QR points
  # at the /classroom funnel. The compact kit counterpart to the app's
  # Profile-driven Communicators::GenerateDeviceTag.
  class DeviceTagSheet
    include SheetRendering

    DEFAULT_PER_PAGE = 2 # two landscape tags stacked on Letter

    def initialize(qr_target_url: nil, per_page: DEFAULT_PER_PAGE)
      @qr_target_url = qr_target_url.presence
      @per_page = per_page.to_i.positive? ? per_page.to_i : DEFAULT_PER_PAGE
    end

    def to_pdf
      render_letter_pdf(
        template: "marketing/device_tag_sheet",
        assigns: {
          card_count: @per_page,
          logo: logo_base64,
          qr_data_url: qr_data_url(@qr_target_url),
        },
      )
    end
  end
end
