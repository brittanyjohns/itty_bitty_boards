class ImagePreprocessor
  def initialize(path) @path = path end

  def process!
    require "mini_magick"
    img = MiniMagick::Image.open(@path)
    # Resize for cost/perf
    max_px = (ENV["IMPORT_MAX_IMAGE_PX"] || "1500").to_i
    img.resize "#{max_px}x#{max_px}>" if img.width > max_px || img.height > max_px

    # Light deskew attempt (MiniMagick: -deskew 40%)
    # If ImageMagick supports it:
    begin
      img.combine_options { |c| c.deskew "40%" }
    rescue
      # Ignore if not supported locally
    end

    # Contrast boost
    img.auto_level
    img.contrast

    # Save to tmp
    out_path = Rails.root.join("tmp", "import_#{SecureRandom.hex(6)}.jpg").to_s
    img.write(out_path)

    { path: out_path, rotation: 0, debug: { resized: true } }
  end
end
