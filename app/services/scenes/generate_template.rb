require "base64"

module Scenes
  # Generates a scene PHOTO for a pending SceneTemplate and runs it through
  # magenta detection.
  #
  # The only thing that goes to the image model is a scene DESCRIPTION an admin
  # typed. Board and product artwork is never sent: the model draws a room with
  # flat magenta placeholders, and real art is warped onto those later by
  # RenderSceneComposition. Nothing here accepts an image, a board or a
  # printable, and that is the guarantee.
  #
  # Paid: one images.generate call plus (BlankBaseInpainter) one images.edit.
  # Its job runs with retry: 0.
  class GenerateTemplate
    SIZES = {
      "landscape" => "1536x1024",
      "portrait" => "1024x1536",
      "square" => "1024x1024",
    }.freeze
    ORIENTATIONS = SIZES.keys.freeze
    MAX_DESCRIPTION_LENGTH = 600
    MAX_SLOT_HINTS_LENGTH = 400
    DEFAULT_QUALITY = "high".freeze

    STAGING_NOTE = "Staging doesn't call OpenAI: this is the placeholder image, so there is nothing " \
                   "to detect. Use \"Upload magenta-marked PNG\" to try detection on staging.".freeze

    # The rules every scene prompt carries. Kept as one constant so the spec
    # can pin that none of them silently drops out.
    MAGENTA_RULES = [
      "Paint EVERY placeholder surface (each sheet of paper, card, tag or screen that artwork will be " \
      "placed on later) a flat, uniform, pure magenta #FF00FF: evenly lit, matte, with no texture, " \
      "no gradient, no pattern, no shadow and no reflections or glare on it.",
      "Keep every placeholder surface completely inside the frame, never cropped by an edge of the image.",
      "Leave a clear gap between placeholder surfaces: no two may touch or overlap.",
      "Nothing else in the scene may be magenta, pink or purple.",
    ].freeze

    NO_TEXT_RULE = "There must be no text, words, letters, numbers, logos or symbols anywhere in the image.".freeze

    ORIENTATION_PHRASES = {
      "landscape" => "a wide landscape frame",
      "portrait" => "a tall portrait frame",
      "square" => "a square frame",
    }.freeze

    def self.quality = ENV.fetch("SCENE_IMAGE_QUALITY", DEFAULT_QUALITY)
    def self.model = ENV.fetch("SCENE_IMAGE_MODEL", OpenAiClient::IMAGE_MODEL)
    def self.request_timeout = Integer(ENV.fetch("SCENE_OPENAI_TIMEOUT", 240))

    def self.build_prompt(description:, slot_hints: nil, orientation: "landscape")
      description = Images::PromptBuilder.sanitize_user_text(description, max_length: MAX_DESCRIPTION_LENGTH)
      raise ArgumentError, "a scene description is required" if description.blank?

      hints = Images::PromptBuilder.sanitize_user_text(slot_hints, max_length: MAX_SLOT_HINTS_LENGTH)
      orientation = orientation.to_s.presence_in(ORIENTATIONS) || "landscape"

      [
        "A photorealistic photograph of a warm, inviting, real-life home or classroom scene, " \
        "in natural light, composed in #{ORIENTATION_PHRASES[orientation]}.",
        "The scene: #{description}",
        ("The placeholder surfaces: #{hints}" if hints),
        *MAGENTA_RULES,
        NO_TEXT_RULE,
      ].compact.join("\n")
    end

    def initialize(template, edit_client: nil)
      @template = template
      @edit_client = edit_client
    end

    def call
      request = @template.generation.to_h.fetch("request", {})
      orientation = request["orientation"].to_s.presence_in(ORIENTATIONS) || "landscape"
      prompt = self.class.build_prompt(description: request["description"], slot_hints: request["slot_hints"],
                                       orientation: orientation)
      @template.update_columns(prompt: prompt)

      response = OpenAiClient.new(
        prompt: prompt,
        size: SIZES[orientation],
        output_format: "png",
        quality: self.class.quality,
        model: self.class.model,
        request_timeout: self.class.request_timeout,
      ).create_image

      bytes = Base64.decode64(response[:b64_json].to_s)
      raise "the image model returned no image" if bytes.empty?

      content_type = response[:content_type].presence || "image/png"
      filename = "ai-scene.#{content_type.split("/").last}"
      @template.source_image.attach(io: StringIO.new(bytes), filename: filename, content_type: content_type,
                                    key: SceneTemplate.versioned_storage_key_for(filename))

      placeholder = response[:model] == "staging-placeholder"
      BuildFromMarkedImage.new(
        template: @template,
        bytes: bytes,
        content_type: content_type,
        inpaint: !placeholder,
        edit_client: @edit_client,
        notes: placeholder ? [STAGING_NOTE] : [],
        generation_extra: {
          "image" => {
            "model" => response[:model],
            "size" => response[:size],
            "quality" => response[:quality],
            "revised_prompt" => response[:revised_prompt],
          }.compact,
        },
      ).call
    end
  end
end
