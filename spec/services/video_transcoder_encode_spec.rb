require "rails_helper"
require "chunky_png"

# The only spec in the suite that runs ffmpeg for real, and it exists because
# the timing of a stills slideshow cannot be verified any other way — every
# other video spec stubs the encode, so a construction that silently produces
# the wrong DURATION passes all of them and ships a listing video a marketplace
# rejects on length.
#
# That is not hypothetical. The obvious construction — the concat demuxer with
# a `duration` per `file` — was measured against ffmpeg 8.1 and does not hold
# the durations it is given: frames of 1s, 2s and 4s produced a 5s clip, and
# the widely-repeated "repeat the last file" workaround produced 11s. This spec
# is what caught it.
#
# Skipped where ffmpeg isn't installed — CI, per the note atop
# spec/sidekiq/process_tile_video_job_spec.rb. Runs in about two seconds
# locally, which is where it earns its keep.
RSpec.describe VideoTranscoder, ".encode_still_sequence" do
  before do
    described_class.reset_availability!
    skip("ffmpeg/ffprobe not installed") unless described_class.available?
  end

  after { described_class.reset_availability! }

  def frame(dir, name, rgb)
    path = File.join(dir, name)
    ChunkyPNG::Image.new(320, 320, ChunkyPNG::Color.rgb(*rgb)).save(path)
    path
  end

  it "holds every frame for the duration it was given, the last one included" do
    Dir.mktmpdir do |dir|
      entries = [
        [frame(dir, "a.png", [200, 40, 40]), 1.0],
        [frame(dir, "b.png", [40, 200, 40]), 2.0],
        [frame(dir, "c.png", [40, 40, 200]), 4.0],
      ]
      output = File.join(dir, "out.mp4")

      expect(described_class.encode_still_sequence(entries, output, max_seconds: 14.5)).to be true

      expect(described_class.duration(output)).to be_within(0.2).of(7.0)
      expect(described_class.video_codec(output)).to eq("h264")
    end
  end

  # The real shape: an intro, a run of page frames, and a longer outro. Ten
  # frames is what a capped board set produces.
  it "reproduces a full listing-video plan's length" do
    Dir.mktmpdir do |dir|
      seconds = [1.6] + Array.new(8) { 0.9 } + [2.6]
      entries = seconds.each_with_index.map do |hold, i|
        [frame(dir, "f#{i}.png", [(i * 20) % 256, 68, 136]), hold]
      end
      output = File.join(dir, "out.mp4")

      described_class.encode_still_sequence(entries, output, max_seconds: 14.5)

      duration = described_class.duration(output)
      expect(duration).to be_within(0.3).of(seconds.sum)
      # The point of the whole exercise: inside Etsy's window.
      expect(duration).to be_between(BoardPrintable::VIDEO_MIN_SECONDS, BoardPrintable::VIDEO_MAX_SECONDS)
    end
  end

  it "never exceeds the ceiling it is given, whatever the frames ask for" do
    Dir.mktmpdir do |dir|
      entries = [[frame(dir, "a.png", [10, 10, 10]), 30.0]]
      output = File.join(dir, "out.mp4")

      described_class.encode_still_sequence(entries, output, max_seconds: 6.0)

      expect(described_class.duration(output)).to be <= 6.2
    end
  end

  it "reports failure rather than raising when handed nothing" do
    Dir.mktmpdir do |dir|
      expect(described_class.encode_still_sequence([], File.join(dir, "out.mp4"), max_seconds: 5.0))
        .to be false
    end
  end
end
