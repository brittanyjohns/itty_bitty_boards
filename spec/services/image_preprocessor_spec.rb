require "rails_helper"

RSpec.describe ImagePreprocessor do
  let(:source) { Rails.root.join("spec/data/path_images/images/happy.png").to_s }

  # ImagePreprocessor shells out to ImageMagick/GraphicsMagick (via MiniMagick),
  # which isn't installed in CI. Skip there; this still runs locally where the
  # binary exists. Production EC2 has ImageMagick, so the real path is exercised.
  before do
    unless system("magick -version > /dev/null 2>&1") || system("convert -version > /dev/null 2>&1")
      skip "ImageMagick/GraphicsMagick not installed in this environment"
    end
  end

  it "writes a processed jpg into tmp/ and leaves the source untouched" do
    before_mtime = File.mtime(source)
    result = described_class.new(source).process!

    begin
      expect(result[:path]).to start_with(Rails.root.join("tmp").to_s)
      expect(result[:path]).to end_with(".jpg")
      expect(File.exist?(result[:path])).to be(true)
      expect(result[:rotation]).to eq(0)
      # non-destructive: original is not modified
      expect(File.mtime(source)).to eq(before_mtime)
    ensure
      File.delete(result[:path]) if result[:path] && File.exist?(result[:path])
    end
  end

  it "downsizes images larger than the max dimension" do
    result = described_class.new(source).process!
    begin
      processed = MiniMagick::Image.open(result[:path])
      max_px = (ENV["IMPORT_MAX_IMAGE_PX"] || "1500").to_i
      expect(processed.width).to be <= max_px
      expect(processed.height).to be <= max_px
    ensure
      File.delete(result[:path]) if result[:path] && File.exist?(result[:path])
    end
  end
end
