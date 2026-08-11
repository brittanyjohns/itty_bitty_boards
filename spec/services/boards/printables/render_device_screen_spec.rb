require "rails_helper"

# What the tablet in the "on a device" slide is actually showing. Grover is
# stubbed but the ERB is not: the point is that the chrome compiles and carries
# the board's own name, since that is the only thing tying the mockup to the
# product being sold.
RSpec.describe Boards::Printables::RenderDeviceScreen do
  let(:rendered_html) { [] }
  let(:rendered_opts) { [] }

  before do
    allow(Grover).to receive(:new) do |html, **opts|
      rendered_html << html
      rendered_opts << opts
      instance_double(Grover, to_png: "png-bytes")
    end
  end

  def thumbnail(width: 1200, height: 900)
    Boards::Printables::RenderPageThumbnails::Thumbnail.new(
      board_id: 1,
      data_uri: "data:image/png;base64,QQ==",
      landscape: true,
      width: width,
      height: height,
    )
  end

  def render(title: "Core Words", thumb: thumbnail)
    described_class.new(title: title, thumbnail: thumb).call
  end

  it "returns a PNG data URI of the shell" do
    expect(render).to eq("data:image/png;base64,#{Base64.strict_encode64("png-bytes")}")
  end

  it "renders at the shell aspect the tablet quads were calibrated for" do
    render

    expect(rendered_opts.first[:viewport]).to include(
      width: described_class::SHELL_WIDTH,
      height: described_class::SHELL_HEIGHT,
    )
  end

  # The app header is what makes the slide read as the live app rather than a
  # photographed sheet, and it carries the BOARD's name — a generic app title
  # would stage some other product.
  it "puts the board's own name in the app header, over the app controls" do
    render(title: "Snack Time")

    html = rendered_html.first
    expect(html).to include("Snack Time")
    expect(html).to include("app-chrome", "sentence-bar", "Sign in")
    expect(html).to include("action play", "action delete", "action download")
  end

  # It is a screenshot of a screen: a printed QR on the glass reads as an ad
  # someone taped to the tablet. The slide carries its own QR in the footer.
  it "never fetches over the network and prints no scan-me band" do
    render

    html = rendered_html.first
    expect(html).not_to include("Created with SpeakAnyWay AAC")
    expect(html).not_to match(%r{src="https?://})
  end

  describe "how the board sits under the chrome" do
    it "centres a board short enough to fit" do
      render(thumb: thumbnail(width: 2400, height: 700))

      expect(rendered_html.first).to include('class="app-body fits"')
    end

    it "top-anchors a taller board so it clips like a real screen" do
      render(thumb: thumbnail(width: 1200, height: 1600))

      expect(rendered_html.first).to include('class="app-body "')
    end
  end

  # A gallery that renders a plainer tablet beats a job that dies on it: the
  # PDFs a buyer receives are untouched by anything here.
  it "returns nil rather than raising when there is no board render" do
    expect(described_class.new(title: "Core Words", thumbnail: nil).call).to be_nil
  end

  it "returns nil when the screenshot fails" do
    allow(Grover).to receive(:new).and_raise(StandardError, "Chrome crashed")

    expect(render).to be_nil
  end
end
