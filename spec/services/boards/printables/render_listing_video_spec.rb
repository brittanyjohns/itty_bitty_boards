require "rails_helper"

RSpec.describe Boards::Printables::RenderListingVideo do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "Core Words") }
  let(:printable) do
    BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id], page_count: 7)
  end

  let(:rendered_html) { [] }
  let(:encoded_entries) { [] }
  let(:encoded_dirs) { [] }

  before do
    grover = instance_double(Grover, to_png: "png-bytes")
    allow(Grover).to receive(:new) do |html, **_opts|
      rendered_html << html
      grover
    end

    allow(VideoTranscoder).to receive(:available?).and_return(true)
    allow(VideoTranscoder).to receive(:duration).and_return(9.0)
    allow(VideoTranscoder).to receive(:encode_still_sequence) do |entries, output, **_opts|
      encoded_entries << entries
      encoded_dirs << File.dirname(output)
      File.binwrite(output, "mp4-bytes")
      true
    end
  end

  def stub_thumbnails!(skip: nil)
    allow(Boards::Printables::RenderPageThumbnails).to receive(:new) do |boards:, **_opts|
      rendered = boards.reject { |b| b.id == skip&.id }
      instance_double(
        Boards::Printables::RenderPageThumbnails,
        call: rendered.to_h { |b| [b.id, thumbnail_for(b)] },
      )
    end
  end

  def thumbnail_for(target)
    Boards::Printables::RenderPageThumbnails::Thumbnail.new(
      board_id: target.id,
      data_uri: "data:image/png;base64,#{target.name.parameterize}",
      landscape: true,
      width: 792,
      height: 500,
    )
  end

  def frame_html = rendered_html.select { |html| html.include?("video-frame") }

  # Etsy rejects a listing video outside 5-15 seconds, and it rejects it at
  # activation time in the seller UI — a long way from anything that could
  # explain why. The plan is a pure function precisely so this can be checked
  # across every board count the admin allows, for free.
  describe "the duration plan" do
    it "lands inside Etsy's window for every board count we allow" do
      (1..BoardPrintable::MAX_BOARDS_CEILING).each do |count|
        seconds = described_class.plan_seconds(count)

        expect(seconds).to be >= BoardPrintable::VIDEO_MIN_SECONDS,
                           "#{count} boards plans #{seconds}s, under Etsy's floor"
        expect(seconds).to be <= BoardPrintable::VIDEO_MAX_SECONDS,
                           "#{count} boards plans #{seconds}s, over Etsy's ceiling"
      end
    end

    it "stops growing once the frame cap is reached" do
      capped = described_class.plan_seconds(described_class::MAX_PAGE_FRAMES)

      expect(described_class.plan_seconds(described_class::MAX_PAGE_FRAMES + 40)).to eq(capped)
    end
  end

  describe "the frames" do
    it "runs intro, then every page in tree order, then the outro" do
      second = create(:board, user: owner, name: "Feelings")
      printable.update!(board_ids: [board.id, second.id], include_subboards: true)
      stub_thumbnails!

      described_class.new(printable: printable).call

      expect(frame_html.length).to eq(4)
      expect(frame_html[0]).to include(Printables::SlideCopy.video_intro_headline(board_count: 2))
      # Root first — a buyer should see the page the listing is named after
      # before any subboard.
      expect(frame_html[1]).to include("data:image/png;base64,core-words")
      expect(frame_html[2]).to include("data:image/png;base64,feelings")
      expect(frame_html[3]).to include("video-outro")
    end

    # The claim nothing else in the listing makes: the links work on paper.
    it "marks every page after the first as one with a way back" do
      second = create(:board, user: owner, name: "Feelings")
      printable.update!(board_ids: [board.id, second.id])
      stub_thumbnails!

      described_class.new(printable: printable).call

      expect(frame_html[1]).not_to include(Printables::SlideCopy.video_back_marker)
      expect(frame_html[2]).to include(Printables::SlideCopy.video_back_marker)
    end

    it "caps the pages it renders rather than paying Grover for all of them" do
      printable.update!(board_ids: Array.new(20) { create(:board, user: owner).id })
      stub_thumbnails!

      described_class.new(printable: printable).call

      expect(frame_html.length).to eq(described_class::MAX_PAGE_FRAMES + 2)
    end

    # Etsy strips the audio, so the outro's claim is read, not heard — and as
    # one string it wrapped wherever the frame ran out of room, leaving "in."
    # alone on the last row. Each clause is its own unbreakable line.
    it "sets the outro's sub one clause per line" do
      stub_thumbnails!

      described_class.new(printable: printable).call

      outro = frame_html.last
      Printables::SlideCopy.video_outro_sub_lines.each do |line|
        expect(outro).to include("<span>#{line}</span>")
      end
    end

    # The listing's QR is scanned off a screen, where the extra modules are
    # free — unlike the printed one, which stays bare (see Qr).
    it "tags the outro QR with the surface it was scanned from" do
      stub_thumbnails!
      allow(Boards::Printables::Qr).to receive(:data_url_for).and_call_original

      described_class.new(printable: printable).call

      expect(Boards::Printables::Qr).to have_received(:data_url_for)
        .with(a_string_including("utm_content=listing_video"), level: Boards::Printables::Qr::SCREEN_ECC)
    end

    # A page whose render failed costs a frame, not the video.
    it "skips a board whose page didn't render" do
      second = create(:board, user: owner, name: "Feelings")
      printable.update!(board_ids: [board.id, second.id])
      stub_thumbnails!(skip: second)

      described_class.new(printable: printable).call

      expect(frame_html.length).to eq(3)
    end
  end

  describe "what reaches the encoder" do
    before do
      stub_thumbnails!
      described_class.new(printable: printable).call
    end

    it "hands over real files on disk, in playback order" do
      paths = encoded_entries.first.map(&:first)
      expect(paths).to all(start_with("/"))
      expect(paths).to all(end_with(".png"))
      expect(paths).to eq(paths.sort)
    end

    # The frame the QR sits on gets the longest hold in the clip, because a
    # buyer may actually be pointing a phone at it.
    it "gives the intro and outro their own holds, and the pages a shared one" do
      seconds = encoded_entries.first.map(&:last)

      expect(seconds.first).to eq(described_class::INTRO_SECONDS)
      expect(seconds.last).to eq(described_class::OUTRO_SECONDS)
      expect(seconds.last).to be > seconds.first
    end

    it "asks for the length its own plan promised" do
      total = encoded_entries.first.sum(&:last)

      expect(total).to be_within(0.01).of(described_class.plan_seconds(1))
    end
  end

  describe "attaching" do
    before { stub_thumbnails! }

    it "stores the clip as a video, out of the buyer's downloads and the gallery" do
      described_class.new(printable: printable).call

      printable.reload
      expect(printable.listing_video?).to be true
      expect(printable.video_file.content_type).to eq("video/mp4")
      expect(printable.files_view).to be_empty
      expect(printable.current_image_files).to be_empty
      expect(printable.listing_video_current?).to be true
    end

    it "records the measured duration, not the planned one" do
      allow(VideoTranscoder).to receive(:duration).and_return(11.25)

      described_class.new(printable: printable).call

      expect(printable.reload.listing_video_view[:duration]).to eq(11.25)
    end

    # Better to ship no video than one Etsy refuses at activation.
    it "discards a clip that lands outside Etsy's window" do
      allow(VideoTranscoder).to receive(:duration).and_return(21.0)

      expect(described_class.new(printable: printable).call).to be_nil
      expect(printable.reload.listing_video?).to be false
    end

    it "cleans up its frames" do
      described_class.new(printable: printable).call

      expect(encoded_dirs.first).to be_present
      expect(Dir.exist?(encoded_dirs.first)).to be false
    end
  end

  # Ten Grover frames is minutes of headless Chrome. Discovering ffmpeg is
  # missing after paying for them is the bug this guards.
  it "renders nothing at all when ffmpeg isn't installed" do
    allow(VideoTranscoder).to receive(:available?).and_return(false)
    stub_thumbnails!

    expect(described_class.new(printable: printable).call).to be_nil
    expect(Grover).not_to have_received(:new)
    expect(printable.reload.listing_video?).to be false
  end
end
