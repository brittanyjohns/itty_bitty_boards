require "tempfile"
require "base64"

module Scenes
  # Takes the magenta OUT of an AI-generated scene so the template's base image
  # shows plain, blank surfaces.
  #
  # One `images.edit` call with a mask covering the magenta (dilated a few
  # pixels to take the antialiased edge with it), then the edited pixels are
  # copied back ONLY inside that mask. gpt-image edits re-draw the whole frame
  # and drift pixels everywhere — a face, a book spine, the fridge's own texture
  # — so everything outside the mask stays byte-identical to the scene the
  # detector and the front layer were measured on.
  #
  # Only ever handed a scene the image model itself generated (source: ai). An
  # uploaded marked PNG never reaches this call: it could carry product art, and
  # product art is never sent to an image model.
  #
  # Fails soft. Disabled (SCENE_INPAINT_ENABLED=false), on staging, with nothing
  # to mask, or when the call errors, the Result carries the untouched scene and
  # a note; the art and front layer cover the slots either way.
  class BlankBaseInpainter
    DILATE_PX = 4

    PROMPT = <<~PROMPT.squish.freeze
      The transparent masked areas are flat magenta placeholder surfaces. Replace
      them with the plain, blank, empty surface that belongs there, such as a
      blank white sheet of paper, a blank card, or a dark switched-off screen,
      continuing the surrounding lighting, perspective, edges and shadows. Do
      not add any text, words, letters, numbers, pictures, patterns, logos or
      new objects. Leave everything outside the masked areas exactly as it is.
    PROMPT

    Result = Struct.new(:image, :inpainted, :note, keyword_init: true)

    def self.enabled? = ENV.fetch("SCENE_INPAINT_ENABLED", "true").to_s.downcase != "false"
    def self.model = ENV.fetch("SCENE_INPAINT_MODEL", ImageEditService::MODEL)
    def self.quality = ENV.fetch("SCENE_IMAGE_QUALITY", Scenes::GenerateTemplate::DEFAULT_QUALITY)

    # regions: [[x0, y0, x1, y1], ...] inclusive boxes to search for magenta
    # (SlotDetector#regions). nil searches the whole image.
    def initialize(image, regions: nil, mask: nil, client: nil, logger: Rails.logger)
      @image = image
      @regions = regions
      @mask = mask || MagentaMask.new(image)
      @client = client
      @logger = logger
    end

    def call
      return fallback("Magenta removal is switched off (SCENE_INPAINT_ENABLED=false).") unless self.class.enabled?
      return fallback("Staging doesn't call OpenAI, so the magenta was not removed.") if AppEnv.staging?

      selection = selected_indices
      return fallback("There was no magenta to remove.") if selection.empty?

      edited = request_edit(selection)
      Result.new(image: composite(edited, selection), inpainted: true, note: nil)
    rescue StandardError => e
      # OpenAI's own message; there is no user data in this request.
      @logger.warn("[Scenes::BlankBaseInpainter] edit failed: #{e.class}: #{e.message.to_s.truncate(300)}")
      fallback("Removing the magenta with OpenAI failed (#{e.class}), so the base keeps it.")
    end

    # Flat pixel indices (y * width + x) of the dilated magenta mask.
    def selected_indices
      w = @image.width
      boxes = @regions.presence || [[0, 0, w - 1, @image.height - 1]]
      selected = {}

      boxes.each do |x0, y0, x1, y1|
        x0 = [x0 - DILATE_PX, 0].max
        y0 = [y0 - DILATE_PX, 0].max
        x1 = [x1 + DILATE_PX, w - 1].min
        y1 = [y1 + DILATE_PX, @image.height - 1].min
        dilate_box(x0, y0, x1, y1).each { |index| selected[index] = true }
      end

      selected.keys
    end

    # Copies `edited` over `@image` at the selected indices only.
    def composite(edited, selection)
      out = ChunkyPNG::Image.new(@image.width, @image.height, @image.pixels.dup)
      selection.each { |index| out.pixels[index] = edited.pixels[index] }
      out
    end

    private

    def fallback(note)
      Result.new(image: @image, inpainted: false, note: note)
    end

    # A square max filter of radius DILATE_PX, separable: each row, then each
    # column, answered from a prefix count so the window size costs nothing.
    def dilate_box(x0, y0, x1, y1)
      bw = x1 - x0 + 1
      bh = y1 - y0 + 1

      raw = Array.new(bw * bh, false)
      bh.times do |by|
        bw.times { |bx| raw[(by * bw) + bx] = @mask.magenta_at?(x0 + bx, y0 + by) }
      end

      horizontal = Array.new(bw * bh, false)
      bh.times do |by|
        row = by * bw
        dilate_line(bw) { |i| raw[row + i] }.each_with_index { |hit, bx| horizontal[row + bx] = hit }
      end

      out = []
      bw.times do |bx|
        dilate_line(bh) { |i| horizontal[(i * bw) + bx] }.each_with_index do |hit, by|
          out << (((y0 + by) * @image.width) + x0 + bx) if hit
        end
      end
      out
    end

    def dilate_line(length)
      prefix = Array.new(length + 1, 0)
      length.times { |i| prefix[i + 1] = prefix[i] + (yield(i) ? 1 : 0) }
      Array.new(length) do |i|
        (prefix[[i + DILATE_PX + 1, length].min] - prefix[[i - DILATE_PX, 0].max]).positive?
      end
    end

    def request_edit(selection)
      w = @image.width
      h = @image.height
      mask_png = ChunkyPNG::Image.new(w, h, ChunkyPNG::Color::BLACK)
      selection.each { |index| mask_png.pixels[index] = ChunkyPNG::Color::TRANSPARENT }

      size = "#{w}x#{h}"
      size = "auto" unless OpenAiClient::IMAGE_SIZES.include?(size)

      with_tempfile("scene", @image.to_blob) do |image_file|
        with_tempfile("mask", mask_png.to_blob) do |mask_file|
          response = client.images.edit(
            parameters: {
              model: self.class.model,
              image: image_file.path,
              mask: mask_file.path,
              prompt: PROMPT,
              size: size,
              quality: self.class.quality,
            },
          )
          decode(response, w, h)
        end
      end
    end

    def decode(response, w, h)
      data = response.to_h.with_indifferent_access.dig(:data, 0) || {}
      b64 = data[:b64_json]
      raise "the edit returned no image data" if b64.blank?

      edited = ChunkyPNG::Image.from_blob(Base64.decode64(b64))
      edited = edited.resample_bilinear(w, h) unless edited.width == w && edited.height == h
      edited
    end

    def with_tempfile(name, bytes)
      file = Tempfile.new([name, ".png"])
      file.binmode
      file.write(bytes)
      file.flush
      yield file
    ensure
      file&.close!
    end

    def client
      @client ||= OpenAI::Client.new(
        access_token: ENV.fetch("OPENAI_ACCESS_TOKEN"),
        request_timeout: Scenes::GenerateTemplate.request_timeout,
      )
    end
  end
end
