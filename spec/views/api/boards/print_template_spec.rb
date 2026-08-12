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

  def render_print(tiles, **overrides)
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
      }.merge(overrides),
    )
  end

  def header_nodes(html)
    Nokogiri::HTML(html).css(".header")
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

  # The QR lives inside the header block, so the header state and the presence
  # of the printed code are one decision. A "header-less" page that also lost
  # its QR is a sheet with no way back to the talking version of the board —
  # which is the promise the whole listing leans on.
  describe "header modes" do
    let(:tiles) { [tile(label: "happy", image_url: "https://cdn.example/happy.png")] }
    let(:qr) { "data:image/png;base64,QQ==" }

    def render_with(mode)
      render_print(
        tiles,
        header_mode: mode,
        hide_header: false,
        qr_data_url: qr,
        qr_target_url: "https://app.speakanyway.com/pb/core-words",
        board_title: "Core Words",
      )
    end

    it "prints the full band — title, scan line and QR — in full mode" do
      html = render_with(Boards::RenderAssetData::HEADER_FULL)

      expect(html).to include("Core Words")
      expect(html).to include("for the full interactive version")
      expect(Nokogiri::HTML(html).at_css(".qr-small img")["src"]).to eq(qr)
    end

    it "keeps the QR and drops everything else in qr_only mode" do
      html = render_with(Boards::RenderAssetData::HEADER_QR_ONLY)
      doc = Nokogiri::HTML(html)

      expect(doc.at_css(".header-qr-only .qr-small img")["src"]).to eq(qr)
      expect(doc.at_css(".board-title")).to be_nil
      expect(doc.at_css(".board-link")).to be_nil
      expect(doc.at_css(".logo")).to be_nil
    end

    it "prints no header at all in none mode" do
      expect(header_nodes(render_with(Boards::RenderAssetData::HEADER_NONE))).to be_empty
    end

    # Callers that render this template with their own assigns still get the
    # old all-or-nothing behaviour instead of an unstyled full header.
    it "falls back to hide_header when no mode was passed" do
      expect(header_nodes(render_print(tiles, hide_header: true))).to be_empty
      expect(header_nodes(render_print(tiles, hide_header: false))).not_to be_empty
    end
  end

  # A tile picture that HANGS — an S3 key not written yet, art still coming back
  # from generation — never fires onerror, so Grover's networkidle0 wait never
  # settles and the board ends up with no preview at all. The deadline swaps
  # those tiles for their placeholder, which cancels the request. It is opt-in
  # because a printable PDF is a paid artifact and must keep waiting for the
  # real symbol.
  describe "unloaded-image deadline" do
    let(:tiles) { [tile(label: "happy", image_url: "https://cdn.example/happy.png")] }

    it "carries the placeholder on the tile so a swap can happen after load" do
      node = tile_nodes(render_print(tiles)).first
      img = node.at_css(".tile-media img")

      expect(img["data-placeholder-src"]).to start_with("data:image/svg+xml")
      expect(img["onerror"]).to include("swapTileToPlaceholder")
    end

    it "arms the deadline when one is given" do
      html = render_print(tiles, image_load_deadline_ms: 8_000)

      expect(html).to include("window.__tileImageDeadlineMs = 8000")
    end

    it "leaves the page waiting indefinitely when no deadline is given" do
      expect(render_print(tiles)).not_to include("__tileImageDeadlineMs =")
    end
  end

  it "still suppresses the caption on an image tile when hide_label is set" do
    html = render_print([tile(label: "cat", image_url: "https://cdn.example/cat.png", hide_label: true)])
    node = tile_nodes(html).first

    expect(node.at_css(".tile-media img")["src"]).to eq("https://cdn.example/cat.png")
    expect(node.at_css(".label")).to be_nil
  end
end
