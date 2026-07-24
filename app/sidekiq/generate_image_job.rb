class GenerateImageJob
  include Sidekiq::Job
  sidekiq_options queue: :ai_images, retry: 2, backtrace: true

  def perform(image_id, user_id = nil, options = {})
    options = {} unless options.is_a?(Hash)
    image_prompt = options["image_prompt"]
    board_id = options["board_id"]
    transparent_bg = options["transparent_bg"]
    style = options["style"]
    raw_prompt = options["raw_prompt"] == true

    image = Image.find(image_id)
    board = Board.find_by(id: board_id) if board_id
    user = User.find_by(id: user_id) || image.user
    # Absent key means "transparent" — that's what every prompt asked for before
    # transparency moved to the API's `background` param. Only an explicit false
    # opts out.
    transparent = transparent_bg != false

    board_image = nil

    begin
      board_image = BoardImage.find_by(board_id: board_id, image_id: image_id) if board_id
      board_image&.update_column(:status, "generating")

      # Persist only the user's intent; the composed prompt stays out of the
      # column so a later regeneration can't wrap the envelope inside itself.
      image.image_prompt = image_prompt if image_prompt.present?
      image.save! if image.changed?

      composed_prompt = resolve_prompt(
        image: image, user_input: image_prompt, board: board, user: user,
        style: style, transparent: transparent, raw_prompt: raw_prompt
      )

      new_doc = generate_with_refusal_retry(image, user_id, composed_prompt, transparent)

      new_doc.update(source_type: "OpenAI")
      if image.menu? && image.image_prompt.to_s.include?(Menu::PROMPT_ADDITION)
        image.image_prompt = image.image_prompt.gsub(Menu::PROMPT_ADDITION, "")
        image.save!
      end
      if board_image
        board_image.update(status: "complete", display_image_url: new_doc.tile_url)
      end
    rescue => e
      Rails.logger.error "**** ERROR **** \n#{e.message}\n#{e.backtrace.join("\n")}"
      image.update(status: "failed", error: e.message)
      board_image&.update_column(:status, "failed")
    end
  end

  private

  # Menu items keep their own description-driven prompt (set at creation from
  # the vision parse); everything else is composed by Images::PromptBuilder.
  # `raw_prompt` is the admin escape hatch for hand-written prompts.
  def resolve_prompt(image:, user_input:, board:, user:, style:, transparent:, raw_prompt:)
    return user_input if raw_prompt && user_input.present?
    return image.image_prompt if image.menu? && image.image_prompt.present?

    Images::PromptBuilder.for_image(
      image,
      user_input: user_input,
      style: style,
      board: board,
      user: user,
      transparent: transparent,
    )
  end

  # A content-policy refusal on a user-written prompt shouldn't leave the tile
  # blank: AAC vocabulary legitimately includes body parts, medical, and
  # bathroom/safety words that trip the moderator. Retry once with the clean
  # label-only house prompt before giving up.
  def generate_with_refusal_retry(image, user_id, composed_prompt, transparent)
    doc = image.create_image_doc(user_id, composed_prompt, transparent: transparent)
    raise "Image generation returned no document" if doc.nil?

    doc
  rescue => e
    raise unless refusal_error?(e)

    fallback = Images::PromptBuilder.for_image(image, transparent: transparent)
    raise if fallback == composed_prompt

    Rails.logger.warn(
      "GenerateImageJob: prompt refused for Image #{image.id}; retrying with the " \
      "default house prompt. (#{e.message})"
    )
    doc = image.create_image_doc(user_id, fallback, transparent: transparent)
    raise "Image generation returned no document" if doc.nil?

    doc
  end

  def refusal_error?(error)
    message = error.message.to_s.downcase
    %w[moderation safety_system safety policy rejected blocked].any? { |m| message.include?(m) }
  end
end
