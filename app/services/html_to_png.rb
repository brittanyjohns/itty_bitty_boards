# One place that turns an HTML string into PNG bytes via Grover (headless
# Chrome). Extracted from Communicators::BaseAssetGenerator so the text-tile
# renderer doesn't have to inherit a communicator asset base class to get at it.
#
# `transparent` maps to Puppeteer's omitBackground, which only shows through
# where the page itself paints nothing — a body with a background color will
# still render opaque, so the caller has to leave it unset too.
module HtmlToPng
  def self.call(html:, width:, height:, scale: 2, transparent: false)
    options = {
      format: "png",
      viewport: { width: width, height: height },
      width: width,
      height: height,
      device_scale_factor: scale,
    }
    options[:omit_background] = true if transparent

    Grover.new(html, **options).to_png
  end
end
