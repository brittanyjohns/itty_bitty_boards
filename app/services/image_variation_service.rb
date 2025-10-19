# app/services/image_variation_service.rb
require "open-uri"
require "tempfile"
require "mini_magick"
require "openai"

class ImageVariationService
  MAX_BYTES = 4 * 1024 * 1024 # 4 MB hard limit from OpenAI
  DEFAULT_SIZE = "1024x1024".freeze

  def initialize(openai_client: default_openai_client, logger: default_logger)
    @client = openai_client
    @logger = logger
  end

  # Public entrypoint
  #
  # @param url [String] The source image URL
  # @param size [String] One of "256x256", "512x512", "1024x1024"
  # @return [String,nil] The URL of the generated variation (or nil on failure)
  def create_variation_from_url(url, size: DEFAULT_SIZE)
    if url.blank?
      log_error "No URL provided for image variation generation"
      return nil
    end

    download = nil
    png_file = nil

    begin
      # 1) Download to a tempfile (unknown format)
      download = download_to_tempfile(url)

      # 2) Ensure PNG + under 4MB (convert if needed)
      png_file = ensure_png(download)
      enforce_size!(png_file)

      # 3) Send to OpenAI (pass a *file*, not a URL)
      create_image_variation(png_file, size:)
    rescue => e
      log_error "Error generating image variation: #{e.message}\n#{e.backtrace.join("\n")}"
      nil
    ensure
      # Make sure to clean up all tempfiles
      safe_close!(download)
      safe_close!(png_file) unless png_file.equal?(download)
    end
  end

  private

  # --- OpenAI call -----------------------------------------------------------

  def create_image_variation(png_tempfile, size:)
    # Important: pass a proper UploadIO with content type image/png
    upload = Faraday::UploadIO.new(png_tempfile.path, "image/png")

    response = @client.images.variations(
      parameters: {
        image: upload,
        n: 1,
        size: size,
      },
    )

    url = response.dig("data", 0, "url")
    log_error "*** ERROR *** Invalid Image Variation Response: #{response.inspect}" unless url
    url
  end

  # --- File handling ---------------------------------------------------------

  def download_to_tempfile(url)
    tf = Tempfile.new(["source", File.extname(URI.parse(url).path.presence || ".bin")])
    tf.binmode
    tf.write(URI.open(url, "rb", redirect: true, read_timeout: 60).read)
    tf.rewind
    tf
  end

  # Ensures the returned file is a PNG Tempfile
  # If input is already PNG, returns the same file.
  # Otherwise converts via MiniMagick to a new PNG tempfile.
  def ensure_png(file)
    image = MiniMagick::Image.read(File.binread(file.path))

    if image.type.to_s.downcase.include?("png")
      # Already PNG
      file
    else
      # Convert to PNG
      png_tf = Tempfile.new(["converted", ".png"])
      png_tf.binmode
      image.format("png")
      image.write(png_tf.path)
      png_tf.rewind
      png_tf
    end
  end

  def enforce_size!(file)
    size = File.size(file.path)
    if size > MAX_BYTES
      # Try lossless strip/optimize; if still too big, raise
      image = MiniMagick::Image.open(file.path)
      image.strip
      image.write(file.path)
      file.rewind

      size = File.size(file.path)
      raise "Image too large after optimization (#{size} bytes, limit #{MAX_BYTES})" if size > MAX_BYTES
    end
  end

  # --- Utilities -------------------------------------------------------------

  def safe_close!(tf)
    return unless tf
    tf.close!
  rescue
    # ignore
  end

  def default_openai_client
    OpenAI::Client.new(access_token: ENV["OPENAI_ACCESS_TOKEN"])
  end

  def default_logger
    defined?(Rails) ? Rails.logger : Logger.new($stdout)
  end

  def log_error(msg)
    @logger&.error(msg)
  end
end
