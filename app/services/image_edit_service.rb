# app/services/image_edit_service.rb
require "open-uri"
require "tempfile"
require "mini_magick"
require "openai"
require "faraday/multipart"
require "base64"
require "stringio"

class ImageEditService
  MAX_BYTES = 4 * 512 * 512 # 4 MB hard limit from OpenAI
  DEFAULT_SIZE = "512x512".freeze

  def initialize(openai_client: default_openai_client, logger: default_logger)
    @client = openai_client
    @logger = logger
  end

  # Returns either a remote URL (if provided by API) OR a data URL ("data:image/png;base64,...")
  def edit_image_from_url(image_url:, prompt:, size: DEFAULT_SIZE)
    raise ArgumentError, "image_url required" if image_url.blank?
    raise ArgumentError, "prompt required" if prompt.blank?

    download = nil
    png_file = nil

    begin
      @logger.debug "Creating image edit for URL: #{image_url}"
      download = download_to_tempfile(image_url)
      png_file = ensure_png(download)
      Rails.logger.debug "Converted image to PNG at #{png_file.path}"
      enforce_size!(png_file)

      create_image_edit(png_file, prompt, size)
    rescue => e
      log_error "Error generating image edit: #{e.message}\n#{e.backtrace.join("\n")}"
      nil
    ensure
      safe_close!(download)
      safe_close!(png_file) unless png_file.equal?(download)
    end
  end

  private

  def create_image_edit(image_file, prompt, size)
    io = File.open(image_file.path, "rb")
    upload = Faraday::UploadIO.new(io, "image/png", "image.png")

    @logger.debug "Sending image edit request to OpenAI with prompt: #{prompt}"
    response = @client.images.edit(
      parameters: {
        model: "gpt-image-1",
        image: upload,
        prompt: prompt,
        # size: size,
        background: "transparent",

      },
    )

    Rails.logger.debug "Received image edit response: #{response.inspect}"

    data = response["data"]&.first || {}
    if (url = data["url"])
      return url
    elsif (b64 = data["b64_json"])
      # Return a data URL you can store or render directly in <img src="">
      data_url = "data:image/png;base64,#{b64}"

      return data_url
      # If you prefer to upload to ActiveStorage and get an https URL instead:
      # decoded = Base64.strict_decode64(b64)
      # blob = ActiveStorage::Blob.create_and_upload!(
      #   io: StringIO.new(decoded),
      #   filename: "openai-edit.png",
      #   content_type: "image/png"
      # )
      # return Rails.application.routes.url_helpers.rails_blob_url(blob, only_path: false)
    end

    log_error "*** ERROR *** Invalid Image Edit Response: #{response.inspect}"
    nil
  rescue Faraday::ClientError => e
    body = e.response&.dig(:body) || e.message
    log_error "OpenAI API Error (#{e.class}): #{body}"
    nil
  ensure
    io&.close
  end

  def download_to_tempfile(url)
    raise ArgumentError, "Invalid image_url" unless url.is_a?(String)

    uri = URI.parse(url)
    raise ArgumentError, "Invalid URI: #{url}" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    ext = File.extname(uri.path.to_s)
    ext = ".png" if ext.nil? || ext.empty?

    tf = Tempfile.new(["source", ext])
    tf.binmode
    @logger.debug "Downloading image from #{url} into #{tf.path}"
    tf.write(URI.open(uri, "rb", redirect: true, read_timeout: 60).read)
    tf.rewind
    tf
  end

  def ensure_png(file)
    image = MiniMagick::Image.read(File.binread(file.path))
    return file if image.type.to_s.downcase.include?("png")

    png_tf = Tempfile.new(["converted", ".png"])
    png_tf.binmode
    image.format("png")
    image.write(png_tf.path)
    png_tf.rewind
    png_tf
  end

  def enforce_size!(file)
    size = File.size(file.path)
    return if size <= MAX_BYTES

    image = MiniMagick::Image.open(file.path)
    image.strip
    image.write(file.path)
    file.rewind

    size = File.size(file.path)
    # raise "Image too large after optimization (#{size} bytes, limit #{MAX_BYTES})" if size > MAX_BYTES
    if size > MAX_BYTES
      log_error "Image too large after optimization (#{size} bytes, limit #{MAX_BYTES})"
      # raise "Image too large after optimization"
    end
  end

  def safe_close!(tf)
    tf&.close!
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
