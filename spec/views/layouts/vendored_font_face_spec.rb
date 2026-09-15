require "rails_helper"

# The Grover layouts inline Nunito's @font-face into a <style> block. ERB's
# `<%=` HTML-escapes a plain String, turning `font-family: 'Nunito';` into
# `font-family: &#39;Nunito&#39;;` — and entities are never decoded inside
# <style>, so Chrome drops the whole @font-face and silently renders in the
# system-ui fallback. Nothing errors; the typeface is just wrong on Etsy.
RSpec.describe "Grover layouts inlining the vendored font", type: :view do
  def render_layout(layout, assigns: {})
    ApplicationController.render(inline: "", layout: layout, assigns: assigns, formats: [:html])
  end

  %w[listing_image listing_image_styled pdf_printable device_screen pdf_care_plan].each do |layout|
    it "emits the @font-face in #{layout} unescaped" do
      html = render_layout(layout)

      expect(html).to include("font-family: 'Nunito';")
      expect(html).to include("data:font/woff2;base64,")
      expect(html).not_to include("&#39;Nunito&#39;")
    end
  end

  # Palette values are constants and carry no quotes today, but a surface
  # written as `url('...')` would break the same way the font did.
  it "emits the listing palette CSS unescaped" do
    css = ":root { --surface: url('data:image/png;base64,AAAA'); }"

    html = render_layout("listing_image", assigns: { palette_css: css })

    expect(html).to include(css)
  end
end
