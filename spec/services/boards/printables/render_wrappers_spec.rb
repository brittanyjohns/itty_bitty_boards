require "rails_helper"

# Grover is stubbed but ApplicationController.render is NOT — the point of this
# spec is that the four wrapper templates and the pdf_printable layout actually
# compile and say the right things. Stubbing the render out (as the Generate
# spec does) would let an ERB typo through every other test.
RSpec.describe Boards::Printables::RenderWrappers do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user, name: "Core Words") }

  let(:rendered) { {} }

  before do
    order = %i[cover how_to_use license credits]
    index = 0
    allow(Grover).to receive(:new) do |html, **_opts|
      rendered[order[index]] = html
      index += 1
      instance_double(Grover, to_pdf: "%PDF-#{index}")
    end
  end

  def render(board_count: 1, topic: nil)
    described_class.new(board: board, board_count: board_count, topic: topic).call
  end

  it "returns bytes for all four wrapper pages" do
    result = render

    expect(result.keys).to contain_exactly(:cover, :how_to_use, :license, :credits)
    expect(result.values).to all(start_with("%PDF"))
  end

  describe "the cover" do
    it "shows the board name and the SpeakAnyWay footer" do
      render

      expect(rendered[:cover]).to include("Core Words")
      expect(rendered[:cover]).to include("A SpeakAnyWay printable")
      expect(rendered[:cover]).to include("speakanyway.com")
    end

    # The cover represents the whole bundle, so its QR is the one that points
    # at the root board; interior pages point at their own (see CollectPages).
    it "embeds a QR image" do
      render

      expect(rendered[:cover]).to include('class="qr"')
      expect(rendered[:cover]).to include("data:image/png;base64,")
    end

    it "describes a single board" do
      render

      expect(rendered[:cover]).to include("A printable communication board")
    end

    it "describes a set by its board count" do
      render(board_count: 4)

      expect(rendered[:cover]).to include("A set of 4 communication boards")
    end

    it "leads with the topic when one was given" do
      render(board_count: 4, topic: "mealtime")

      expect(rendered[:cover]).to include("Words for mealtime")
    end
  end

  describe "the how-to-use page" do
    it "explains the two prints of one board for a single board" do
      render

      expect(rendered[:how_to_use]).to include("This communication board")
      expect(rendered[:how_to_use]).to include("page 1 in full color")
      expect(rendered[:how_to_use]).to include("The same board")
    end

    it "explains the colour/low-ink halves for a set" do
      render(board_count: 4)

      expect(rendered[:how_to_use]).to include("set of 4 communication boards")
      expect(rendered[:how_to_use]).to include("prints every board twice")
      expect(rendered[:how_to_use]).to include("Every board")
    end

    it "names the topic when one was given" do
      render(topic: "mealtime")

      expect(rendered[:how_to_use]).to include("mealtime")
    end
  end

  it "renders the personal-use license terms" do
    render

    expect(rendered[:license]).to include("License")
    expect(rendered[:license]).to include("personal and classroom use")
    expect(rendered[:license]).to include("Resell or redistribute")
  end

  it "renders the credits page with a QR back to the board" do
    render

    expect(rendered[:credits]).to include("About SpeakAnyWay")
    expect(rendered[:credits]).to include("data:image/png;base64,")
  end

  # The pipeline's base.css @imports Nunito from Google Fonts. A network fetch
  # inside PDF generation is a flaky failure mode, so the layout must not.
  it "never reaches out to the network for fonts" do
    render

    expect(rendered[:cover]).not_to include("fonts.googleapis.com")
    expect(rendered[:cover]).to include("system-ui")
  end
end
