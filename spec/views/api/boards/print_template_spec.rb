require "rails_helper"
require "nokogiri"

# Renders the shared board print template (used for the user PDF export and the
# preview/cover PNG) with controlled tile data, to lock in how label-only tiles
# are drawn: as the placeholder-image label, with NO duplicate caption beneath.
RSpec.describe "api/boards/print.html.erb", type: :view do
  def tile(label:, image_url:, hide_label: false)
    {
      "x" => 0, "y" => 0, "w" => 1, "h" => 1,
      "label" => label,
      "image_url" => image_url,
      "bg_color" => "#FFFFFF",
      "border_color" => "#000000",
      "border_width" => 0,
      "border_radius" => 0,
      "hide_label" => hide_label,
      "i" => label,
    }
  end

  def render_print(tiles)
    ApplicationController.render(
      template: "api/boards/print",
      layout: "pdf",
      assigns: {
        hide_header: true,
        hide_colors: false,
        logo: nil,
        board_title: "Test",
        board_expires_at: nil,
        qr_data_url: nil,
        qr_target_url: nil,
        columns: tiles.size,
        rows: 1,
        tiles: tiles,
        board_render_width_mm: 200,
        board_render_height_mm: 100,
        landscape: false,
        bw: false,
      },
    )
  end

  def tile_nodes(html)
    Nokogiri::HTML(html).css(".board-grid > .tile")
  end

  it "renders an image tile with its picture and a caption underneath" do
    html = render_print([tile(label: "happy", image_url: "https://cdn.example/happy.png")])
    node = tile_nodes(html).first

    expect(node.at_css(".tile-media img")["src"]).to eq("https://cdn.example/happy.png")
    expect(node.at_css(".label")&.text&.strip).to eq("happy")
  end

  it "renders a label-only tile as placeholder text with NO duplicate caption" do
    html = render_print([tile(label: "I feel", image_url: nil)])
    node = tile_nodes(html).first

    # The label is drawn as the generated placeholder image (an inline SVG),
    # never a borrowed picture...
    placeholder = node.at_css(".tile-media img.tile-placeholder-image")
    expect(placeholder).to be_present
    expect(placeholder["src"]).to start_with("data:image/svg+xml")

    # ...and the separate caption <div class="label"> is suppressed so the
    # label doesn't appear twice.
    expect(node.at_css(".label")).to be_nil
  end

  it "still suppresses the caption on an image tile when hide_label is set" do
    html = render_print([tile(label: "cat", image_url: "https://cdn.example/cat.png", hide_label: true)])
    node = tile_nodes(html).first

    expect(node.at_css(".tile-media img")["src"]).to eq("https://cdn.example/cat.png")
    expect(node.at_css(".label")).to be_nil
  end
end
