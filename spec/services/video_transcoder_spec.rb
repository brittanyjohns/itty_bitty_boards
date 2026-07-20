require "rails_helper"

# ffmpeg/ffprobe aren't installed on CI, so every shellout is stubbed here.
# These specs pin the contract the callers rely on: fail soft, never raise.
RSpec.describe VideoTranscoder do
  before { described_class.reset_availability! }
  after { described_class.reset_availability! }

  def status(success)
    instance_double(Process::Status, success?: success)
  end

  describe ".available?" do
    it "is true only when both binaries are on PATH" do
      allow(Open3).to receive(:capture3).with("which", "ffmpeg").and_return(["", "", status(true)])
      allow(Open3).to receive(:capture3).with("which", "ffprobe").and_return(["", "", status(true)])

      expect(described_class).to be_available
    end

    it "is false when ffprobe is missing" do
      allow(Open3).to receive(:capture3).with("which", "ffmpeg").and_return(["", "", status(true)])
      allow(Open3).to receive(:capture3).with("which", "ffprobe").and_return(["", "", status(false)])

      expect(described_class).not_to be_available
    end

    it "memoizes so the PATH check doesn't run on every upload" do
      allow(Open3).to receive(:capture3).and_return(["", "", status(true)])

      3.times { described_class.available? }

      expect(Open3).to have_received(:capture3).twice
    end
  end

  describe ".duration" do
    it "parses the ffprobe output into seconds" do
      allow(Open3).to receive(:capture3).and_return(["12.480000\n", "", status(true)])

      expect(described_class.duration("/tmp/clip.mp4")).to be_within(0.01).of(12.48)
    end

    it "returns nil when ffprobe exits non-zero" do
      allow(Open3).to receive(:capture3).and_return(["", "boom", status(false)])

      expect(described_class.duration("/tmp/clip.mp4")).to be_nil
    end

    it "returns nil rather than 0.0 for unreadable output" do
      allow(Open3).to receive(:capture3).and_return(["N/A\n", "", status(true)])

      expect(described_class.duration("/tmp/clip.mp4")).to be_nil
    end

    it "returns nil instead of raising when the binary is absent" do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

      expect { described_class.duration("/tmp/clip.mp4") }.not_to raise_error
      expect(described_class.duration("/tmp/clip.mp4")).to be_nil
    end
  end

  describe ".video_codec" do
    it "returns the codec name" do
      allow(Open3).to receive(:capture3).and_return(["hevc\n", "", status(true)])

      expect(described_class.video_codec("/tmp/clip.mov")).to eq("hevc")
    end

    it "returns nil on failure" do
      allow(Open3).to receive(:capture3).and_return(["", "", status(false)])

      expect(described_class.video_codec("/tmp/clip.mov")).to be_nil
    end
  end

  describe ".transcode" do
    let(:output) { Tempfile.new(["out", ".mp4"]) }
    after { output.close! }

    it "passes the duration cap and faststart flag to ffmpeg" do
      output.write("x")
      output.flush
      allow(Open3).to receive(:capture3).and_return(["", "", status(true)])

      expect(described_class.transcode("/tmp/in.mov", output.path, max_seconds: 30)).to be(true)
      expect(Open3).to have_received(:capture3) do |*args|
        expect(args).to include("-t", "30")
        expect(args).to include("-movflags", "+faststart")
        expect(args).to include("libx264")
      end
    end

    it "returns false when ffmpeg exits non-zero" do
      allow(Open3).to receive(:capture3).and_return(["", "error", status(false)])

      expect(described_class.transcode("/tmp/in.mov", output.path, max_seconds: 30)).to be(false)
    end

    it "returns false when ffmpeg succeeds but writes an empty file" do
      allow(Open3).to receive(:capture3).and_return(["", "", status(true)])

      expect(described_class.transcode("/tmp/in.mov", output.path, max_seconds: 30)).to be(false)
    end
  end
end
