require "rails_helper"

# ffmpeg isn't installed on CI, so VideoTranscoder is stubbed throughout.
# What's pinned here is the job's decision-making: when it transcodes, when it
# passes through, and — most importantly — that a failure never destroys the
# user's uploaded clip.
RSpec.describe ProcessTileVideoJob do
  subject(:run) { described_class.new.perform(board_image.id) }

  let(:user)        { create(:user) }
  let(:board)       { create(:board, user: user) }
  let(:board_image) { create(:board_image, board: board) }

  # Stands in for an upload that already went through the controller.
  def attach_video(content_type: "video/mp4", filename: "clip.mp4")
    board_image.video_clip.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/tiny_video.mp4")),
      filename: filename,
      content_type: content_type,
    )
    board_image.reload
    board_image.set_uploaded_video!(board_image.video_clip_url, content_type)
    board_image
  end

  before do
    allow(VideoTranscoder).to receive(:available?).and_return(true)
    allow(board).to receive(:broadcast_board_update!)
    allow_any_instance_of(Board).to receive(:broadcast_board_update!)
  end

  context "when ffmpeg is unavailable" do
    it "leaves the original clip attached and playable" do
      attach_video
      allow(VideoTranscoder).to receive(:available?).and_return(false)

      run

      board_image.reload
      expect(board_image.video_clip).to be_attached
      expect(board_image.data["video"]["url"]).to be_present
      expect(board_image.video_processed?).to be(false)
    end

    it "does not attempt to probe or transcode" do
      attach_video
      allow(VideoTranscoder).to receive(:available?).and_return(false)
      allow(VideoTranscoder).to receive(:duration)
      allow(VideoTranscoder).to receive(:transcode)

      run

      expect(VideoTranscoder).not_to have_received(:duration)
      expect(VideoTranscoder).not_to have_received(:transcode)
    end
  end

  context "when the clip is already web-safe and within the cap" do
    it "marks it processed without re-encoding" do
      attach_video
      allow(VideoTranscoder).to receive(:duration).and_return(12.5)
      allow(VideoTranscoder).to receive(:video_codec).and_return("h264")
      allow(VideoTranscoder).to receive(:transcode)

      run

      board_image.reload
      expect(VideoTranscoder).not_to have_received(:transcode)
      expect(board_image.video_processed?).to be(true)
      expect(board_image.data["video"]["duration"]).to eq(12.5)
      expect(board_image.data["video"]["content_type"]).to eq("video/mp4")
    end

    it "re-encodes an mp4 that is not h264" do
      attach_video
      allow(VideoTranscoder).to receive(:duration).and_return(12.5)
      allow(VideoTranscoder).to receive(:video_codec).and_return("hevc")
      allow(VideoTranscoder).to receive(:transcode) do |_in, out, **|
        File.write(out, "transcoded")
        true
      end

      run

      expect(VideoTranscoder).to have_received(:transcode)
      expect(board_image.reload.video_processed?).to be(true)
    end
  end

  context "when the clip exceeds the 30s cap" do
    before do
      attach_video(content_type: "video/quicktime", filename: "clip.mov")
      allow(VideoTranscoder).to receive(:duration).and_return(48.0)
      allow(VideoTranscoder).to receive(:video_codec).and_return("hevc")
      allow(VideoTranscoder).to receive(:transcode) do |_in, out, **|
        File.write(out, "transcoded")
        true
      end
    end

    it "trims to the cap and records the trimmed duration" do
      run

      board_image.reload
      expect(VideoTranscoder).to have_received(:transcode).with(
        anything, anything, max_seconds: BoardImage::MAX_VIDEO_DURATION_SECONDS
      )
      expect(board_image.data["video"]["duration"]).to eq(30.0)
    end

    it "replaces the .mov with a web-safe mp4" do
      run

      board_image.reload
      expect(board_image.data["video"]["content_type"]).to eq("video/mp4")
      expect(board_image.video_clip.blob.content_type).to eq("video/mp4")
      expect(board_image.video_clip.blob.filename.to_s).to end_with(".mp4")
      expect(board_image.data["video"]["url"]).to be_present
    end
  end

  context "when the transcode fails" do
    it "leaves the original clip attached rather than destroying it" do
      attach_video(content_type: "video/quicktime", filename: "clip.mov")
      original_key = board_image.video_clip.blob.key
      allow(VideoTranscoder).to receive(:duration).and_return(48.0)
      allow(VideoTranscoder).to receive(:video_codec).and_return("hevc")
      allow(VideoTranscoder).to receive(:transcode).and_return(false)

      run

      board_image.reload
      expect(board_image.video_clip).to be_attached
      expect(board_image.video_clip.blob.key).to eq(original_key)
      expect(board_image.video_processed?).to be(false)
    end

    it "leaves the clip alone when the duration can't be probed" do
      attach_video
      allow(VideoTranscoder).to receive(:duration).and_return(nil)
      allow(VideoTranscoder).to receive(:transcode)

      run

      expect(VideoTranscoder).not_to have_received(:transcode)
      expect(board_image.reload.video_processed?).to be(false)
    end
  end

  describe "idempotency" do
    it "does nothing on a second run, so a Sidekiq retry can't double-transcode" do
      attach_video
      allow(VideoTranscoder).to receive(:duration).and_return(12.5)
      allow(VideoTranscoder).to receive(:video_codec).and_return("h264")
      allow(VideoTranscoder).to receive(:transcode)

      run
      described_class.new.perform(board_image.id)

      expect(VideoTranscoder).to have_received(:duration).once
    end
  end

  describe "guards" do
    it "no-ops for a missing board image" do
      expect { described_class.new.perform(-1) }.not_to raise_error
    end

    it "no-ops when the tile has no attached clip" do
      allow(VideoTranscoder).to receive(:duration)

      described_class.new.perform(board_image.id)

      expect(VideoTranscoder).not_to have_received(:duration)
    end

    it "no-ops for a youtube video config" do
      board_image.set_youtube_video!("dQw4w9WgXcQ")
      allow(VideoTranscoder).to receive(:duration)

      run

      expect(VideoTranscoder).not_to have_received(:duration)
    end
  end
end
