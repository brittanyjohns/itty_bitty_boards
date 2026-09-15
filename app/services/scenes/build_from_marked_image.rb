module Scenes
  # Turns a magenta-marked scene into a draft template: detected slots, a front
  # layer, and a base image. Shared by both ways a marked scene arrives — an AI
  # generation (GenerateTemplate) and an admin's "Upload magenta-marked PNG" —
  # so the two can't detect differently.
  #
  # `inpaint:` is true ONLY for a scene the image model generated. An upload
  # keeps its magenta in the base (see BlankBaseInpainter for why it is never
  # sent to OpenAI).
  #
  # Detection is a proposal, not a calibration: the template stays `draft` and
  # the admin nudges the corners in the calibrator. If the model's own slot
  # validation refuses what detection found, the image still saves and the
  # slots are handed to the calibrator unsaved.
  class BuildFromMarkedImage
    NO_SLOTS_ERROR = "No magenta placeholder surfaces were found, so no slots were added. " \
                     "Each surface must be painted flat #FF00FF and the scene saved as a PNG; " \
                     "or add the slots by hand in the calibrator.".freeze
    FALLBACK_BASE_NOTE = "The base image still has its magenta. The art and the front layer cover " \
                         "each slot, but a pink fringe can show at a slot's edge: if it does, push that " \
                         "slot's corners out or raise its bleed in the calibrator.".freeze

    def initialize(template:, bytes:, content_type:, inpaint:, edit_client: nil, notes: [], generation_extra: {})
      @template = template
      @bytes = bytes
      @content_type = content_type.to_s
      @inpaint = inpaint
      @edit_client = edit_client
      @notes = Array(notes)
      @generation_extra = generation_extra.to_h.stringify_keys
    end

    def call
      png = self.class.png_bytes(@bytes, @content_type)
      image = ChunkyPNG::Image.from_blob(png)
      mask = MagentaMask.new(image)
      detector = SlotDetector.new(image, mask: mask, category: @template.category)
      slots = detector.call

      notes = @notes.dup
      base_bytes = png
      front = nil
      inpainted = false
      error = nil

      if slots.empty?
        error = NO_SLOTS_ERROR
      else
        front = FrontLayerExtractor.new(image, slots, mask: mask).call
        if @inpaint
          result = BlankBaseInpainter.new(image, regions: detector.regions, mask: mask, client: @edit_client).call
          if result.inpainted
            base_bytes = result.image.to_blob
            inpainted = true
          else
            notes << result.note << FALLBACK_BASE_NOTE
          end
        else
          notes << FALLBACK_BASE_NOTE
        end
      end

      @template.assign_base_image(io: StringIO.new(base_bytes), filename: "base.png", content_type: "image/png")
      if front
        @template.assign_front_layer(io: StringIO.new(front.to_blob), filename: "front.png", content_type: "image/png")
      end
      @template.slots = slots
      @template.generation = @template.generation.to_h.merge(@generation_extra).merge(
        "state" => error ? SceneTemplate::GENERATION_FAILED : SceneTemplate::GENERATION_COMPLETE,
        "finished_at" => Time.current.iso8601,
        "detected_slots" => slots.size,
        "inpainted" => inpainted,
        "notes" => notes.compact,
        "error" => error,
      ).compact
      @template.notes = [@template.notes.presence, *notes.compact, error].compact.join("\n")

      return @template if @template.save

      @template.generation = @template.generation.merge(
        "unsaved_slots" => slots,
        "slot_errors" => @template.errors.full_messages,
      )
      @template.slots = []
      @template.save!
      @template
    end

    # ChunkyPNG reads PNG only; anything else (the staging placeholder is a
    # JPEG) is converted with libvips, which SceneTemplate already requires.
    PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b.freeze

    def self.png_bytes(bytes, _content_type = nil)
      return bytes if bytes.to_s.b.start_with?(PNG_SIGNATURE)

      require "vips"
      image = Vips::Image.new_from_buffer(bytes, "")
      image = image.colourspace(:srgb) unless image.interpretation == :srgb
      image = image.cast(:uchar) unless image.format == :uchar
      image.write_to_buffer(".png")
    end
  end
end
