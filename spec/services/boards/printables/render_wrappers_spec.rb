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
    order = %i[cover how_to_use license credits cover_low_ink how_to_use_low_ink how_to_use_trim_ready]
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

      expect(rendered[:cover]).to include('class="qr-card"')
      expect(rendered[:cover]).to include("data:image/png;base64,")
    end

    # A printable gets photocopied, laminated, and handed to people without a
    # phone camera. The QR is the convenient path back to the board, not the
    # only one, so the URL is printed as text beside it.
    it "prints the board URL as readable text, not only inside the QR" do
      board.update!(slug: "core-words")

      render

      expect(rendered[:cover]).to include("app.speakanyway.com/pb/core-words")
    end

    # The QR is a PNG by the time it reaches the template, so the encoded URL
    # can only be checked at the point it is handed to RQRCode.
    it "encodes the slug URL, matching Board#public_url" do
      board.update!(slug: "core-words")
      allow(RQRCode::QRCode).to receive(:new).and_call_original

      render

      expect(RQRCode::QRCode).to have_received(:new)
        .with("https://app.speakanyway.com/pb/core-words")
    end

    it "encodes the id when the board has no slug" do
      board.update_column(:slug, "")
      allow(RQRCode::QRCode).to receive(:new).and_call_original

      render

      expect(RQRCode::QRCode).to have_received(:new)
        .with("https://app.speakanyway.com/pb/#{board.id}")
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
    it "explains the three prints of one board for a single board" do
      render

      expect(rendered[:how_to_use]).to include("This communication board")
      expect(rendered[:how_to_use]).to include("includes the board three times")
      expect(rendered[:how_to_use]).to include("The same board")
    end

    # A set ships as three separate FILES (MergePdf#call), and this page is bound
    # into each one, so it describes the file it's in and nothing else. Naming
    # the other file would raise a question this page can't answer — the reader
    # is holding one print, not a pair.
    describe "for a set" do
      it "tells the colour file it is the colour print" do
        render(board_count: 4)

        expect(rendered[:how_to_use]).to include("set of 4 communication boards")
        expect(rendered[:how_to_use]).to include("Printed in full color")
        expect(rendered[:how_to_use]).to include("Every board")
      end

      it "tells the low-ink file it is the low-ink print" do
        render(board_count: 4)

        expect(rendered[:how_to_use_low_ink]).to include("Printed low-ink")
        expect(rendered[:how_to_use_low_ink]).to include("white tile backgrounds")
      end

      # The trim-ready file is the one whose QR moved, so it is the one page
      # that has to say where the code went — a buyer who can't find it assumes
      # the header-less print is the one without the audio companion.
      it "tells the trim-ready file the header is gone and the QR moved" do
        render(board_count: 4)

        expect(rendered[:how_to_use_trim_ready]).to include("Printed to the edges")
        expect(rendered[:how_to_use_trim_ready]).to include("drops the page header")
        expect(rendered[:how_to_use_trim_ready]).to include("QR code moves to the top corner")
      end

      it "never mentions the other files from any one of them" do
        render(board_count: 4)

        [
          rendered[:how_to_use],
          rendered[:how_to_use_low_ink],
          rendered[:how_to_use_trim_ready],
        ].each do |html|
          expect(html).not_to include("three files")
          expect(html).not_to include("three times")
        end
      end

      it "renders the per-variant how-tos only for a set" do
        set = render(board_count: 4)
        expect(set).to have_key(:how_to_use_low_ink)
        expect(set).to have_key(:how_to_use_trim_ready)

        single = render
        expect(single).not_to have_key(:how_to_use_low_ink)
        expect(single).not_to have_key(:how_to_use_trim_ready)
      end

      # The trim-ready file is full colour: rendering it a second cover would
      # be the same pixels and one more Grover run per printable.
      it "reuses the colour cover for the trim-ready file" do
        expect(render(board_count: 4)).not_to have_key(:cover_trim_ready)
      end
    end

    it "names the topic when one was given" do
      render(topic: "mealtime")

      expect(rendered[:how_to_use]).to include("mealtime")
    end

    # Viewing needs nothing; editing needs an account. The two claims sit two
    # paragraphs apart, so they must not read as contradicting each other.
    it "says an account is needed to edit, without undercutting free viewing" do
      render

      expect(rendered[:how_to_use]).to include("create a free account")
      expect(rendered[:how_to_use]).to include("the shared version isn't")
      expect(rendered[:how_to_use]).to include("No sign-in, no subscription")
    end

    it "warns that a shared board can drift from the print" do
      render

      expect(rendered[:how_to_use]).to include("may stop matching this print")
    end

    # The QR opens a web page, not a native app — three pages used to describe
    # the same destination three different ways.
    it "describes the QR destination as online rather than an app install" do
      render

      expect(rendered[:how_to_use]).to include("Nothing to install")
      expect(rendered[:how_to_use]).not_to include("in the free SpeakAnyWay app")
    end
  end

  # One list, not two boxes: the check/cross mark carries the yes/no, so both
  # the permissions and the restrictions sit in a single <ul class="terms">.
  it "renders the personal-use license terms as one list" do
    render

    expect(rendered[:license]).to include("License")
    expect(rendered[:license]).to include("personal and classroom use")
    expect(rendered[:license]).to include("Print as many copies as you need")
    expect(rendered[:license]).to include("resell or redistribute")
    expect(rendered[:license].scan('<ul class="terms">').length).to eq(1)
  end

  it "renders the credits page with a QR back to the board" do
    render

    expect(rendered[:credits]).to include("About SpeakAnyWay")
    expect(rendered[:credits]).to include("data:image/png;base64,")
  end

  # MergePdf emits a separate low-ink FILE for a set, and it opens on its own
  # cover so page one doesn't contradict the filename. A single board is one
  # document holding both halves, so there is nothing to distinguish.
  describe "the ink-light cover" do
    it "is rendered for a set and marked ink-light" do
      result = render(board_count: 4)

      expect(result).to have_key(:cover_low_ink)
      expect(rendered[:cover_low_ink]).to include('<body class="ink-light">')
    end

    it "is not rendered for a single board" do
      result = render

      expect(result).not_to have_key(:cover_low_ink)
    end

    # Asserted on <body> specifically: the .ink-light rules live in the shared
    # layout, so the string appears in every render regardless.
    it "leaves the colour cover unmarked" do
      render(board_count: 4)

      expect(rendered[:cover]).to include('<body class="">')
      expect(rendered[:cover_low_ink]).to include('<body class="ink-light">')
    end

    # Same copy, same boxes — only fills differ. If the two covers could
    # disagree about layout they could disagree about page count, and the two
    # files would stop being interchangeable.
    it "says exactly what the colour cover says" do
      render(board_count: 4)

      expect(rendered[:cover_low_ink]).to include("Core Words")
      expect(rendered[:cover_low_ink]).to include("A set of 4 communication boards")
      expect(rendered[:cover_low_ink]).to include("Scan to hear these words out loud")
    end
  end

  # The pipeline's base.css @imports Nunito from Google Fonts. A network fetch
  # inside PDF generation is a flaky failure mode — and a font that fails to
  # load fails *silently* into the fallback — so the layout inlines it instead.
  it "never reaches out to the network for fonts" do
    render

    expect(rendered[:cover]).not_to include("fonts.googleapis.com")
    expect(rendered[:cover]).not_to include("fonts.gstatic.com")
    expect(rendered[:cover]).to include("data:font/woff2;base64,")
    expect(rendered[:cover]).to include("font-family: Nunito")
    expect(rendered[:cover]).to include("system-ui")
  end

  # Headless Chrome on the render box has no guaranteed colour-emoji font, so
  # an emoji in a wrapper prints as a tofu box. The About page shipped a 💙
  # until it was swapped for an inline SVG; nothing may bring one back.
  it "renders no emoji on any wrapper page" do
    emoji = /[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}]/

    render(board_count: 4)

    rendered.each do |page, html|
      expect(html).not_to match(emoji), "expected no emoji on the #{page} page"
    end
  end
end
