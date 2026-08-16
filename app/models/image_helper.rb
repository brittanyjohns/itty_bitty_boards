require "open-uri"

module ImageHelper
  include UtilHelper
  include AudioHelper

  def name_to_send
    open_ai_opts[:prompt] || name
  end

  def save_image(url, user_id = nil, revised_prompt = nil, edited_prompt = nil, source_type = "OpenAI")
    return if Rails.env.test?

    begin
      downloaded_image = Down.download(url)
      user_id ||= self.user_id
      raw_txt = edited_prompt || name_to_send

      doc = self.docs.create!(
        raw: raw_txt,
        user_id: user_id,
        processed: revised_prompt,
        source_type: source_type,
        original_image_url: url,
      )
      content_type = downloaded_image.content_type.presence || "image/webp"
      ext = content_type.split("/").last || "webp"

      doc.image.attach(
        io: downloaded_image,
        filename: "img_#{self.id}_doc_#{doc.id}.#{ext}",
        content_type: content_type,
      )
      Rails.logger.debug "Image saved and attached to doc #{doc.id} for image #{self.id}"
      doc.queue_tile_variant_render!

      self.update(status: "finished")
    rescue => e
      puts "ImageHelper ERROR: #{e.inspect}"
      raise e
    end

    doc
  end

  def save_from_url(url, processed, raw_txt, file_format = "image/webp", user_id = nil, source_type = "GoogleSearch")
    return if Rails.env.test?

    begin
      downloaded_image = Down.download(url)
      user_id ||= self.user_id
      ext = file_format.split("/").last || "webp"

      doc = self.docs.create!(
        raw: raw_txt,
        user_id: user_id,
        processed: processed,
        source_type: source_type,
        original_image_url: url,
      )

      if downloaded_image
        doc.image.attach(
          io: downloaded_image,
          filename: "img_#{self.id}_doc_#{doc.id}.#{ext}",
          content_type: file_format,
        )

        doc.queue_tile_variant_render!
      end

      self.update(status: "finished", src_url: doc.tile_url)
      update_all_boards_image_belongs_to(doc.tile_url, false, user_id)
    rescue => e
      Rails.logger.error "ImageHelper ERROR: #{e.inspect}"
      raise e
    end

    doc
  end

  def create_image(user_id = nil, image_prompt = nil, transparent: true)
    return if Rails.env.test?

    user_id ||= self.user_id

    opts = open_ai_opts.merge(transparent: transparent)
    opts = opts.merge(prompt: image_prompt) if image_prompt.present?

    response = OpenAiClient.new(opts).create_image

    b64_json = response[:b64_json]
    revised_prompt = response[:revised_prompt]
    edited_prompt = response[:edited_prompt]
    output_format = response[:output_format]
    unless b64_json.present?
      Rails.logger.error "**** ERROR - create_image ****\nDid not receive b64_json.\n#{response.inspect}"
      return nil
    end

    save_image_from_base64(
      b64_json,
      user_id,
      revised_prompt,
      edited_prompt,
      "OpenAI",
      output_format,
      generation_metadata: {
        "prompt" => edited_prompt,
        "model" => response[:model],
        "quality" => response[:quality],
        "background" => response[:background],
      }
    )
  end

  def save_image_from_base64(
    b64_json,
    user_id = nil,
    revised_prompt = nil,
    edited_prompt = nil,
    source_type = "OpenAI",
    output_format = "webp",
    generation_metadata: {}
  )
    return if Rails.env.test?

    user_id ||= self.user_id
    raw_txt = edited_prompt.presence || name_to_send

    format = output_format.to_s.downcase
    format = "webp" unless %w[png jpeg webp].include?(format)

    content_type = case format
      when "png" then "image/png"
      when "jpeg" then "image/jpeg"
      else "image/webp"
      end

    ext = case format
      when "png" then "png"
      when "jpeg" then "jpg"
      else "webp"
      end

    decoded_image = Base64.decode64(b64_json)

    # gpt-image models don't return a revised_prompt (DALL-E 3 did), so without
    # recording the prompt we actually sent there is no way to audit or A/B
    # image quality after the fact. Keep it on the doc.
    final_prompt = generation_metadata["prompt"].presence || edited_prompt

    doc = self.docs.create!(
      raw: raw_txt,
      user_id: user_id,
      processed: revised_prompt.presence || final_prompt,
      source_type: source_type,
      data: {
        b64_json: true,
        output_format: format,
        content_type: content_type,
      }.merge(generation_metadata.compact),
    )

    doc.image.attach(
      io: StringIO.new(decoded_image),
      filename: "img_#{self.id}_doc_#{doc.id}.#{ext}",
      content_type: content_type,
    )

    doc.ensure_tile_variant!

    self.update!(status: "finished")
    update_all_boards_image_belongs_to(doc.tile_url, false, user_id)

    doc
  rescue => e
    Rails.logger.error "ImageHelper ERROR: #{e.class} - #{e.message}"
    raise
  end

  def normalize_image_format(format)
    value = format.to_s.downcase
    return value if %w[png jpeg webp].include?(value)
    "png"
  end

  def content_type_for_image_format(format)
    case format
    when "png" then "image/png"
    when "jpeg" then "image/jpeg"
    when "webp" then "image/webp"
    else "image/png"
    end
  end

  def extension_for_image_format(format)
    case format
    when "png" then "png"
    when "jpeg" then "jpg"
    when "webp" then "webp"
    else "png"
    end
  end

  def get_image_prompt_suggestion(viewing_user_id = nil)
    return if Rails.env.test?
    style = Images::PromptBuilder.resolve_style(user: user)
    opts = open_ai_opts.merge(
      prompt: label,
      style_clause: Images::PromptBuilder::STYLES[style],
    )
    prompt = OpenAiClient.new(opts).get_image_prompt_suggestion
    if prompt
      if user_id == viewing_user_id
        self.update(revised_prompt: prompt)
      end
      puts "Returning prompt: #{prompt}"
      prompt
    else
      Rails.logger.error "**** ERROR - get_image_prompt_suggestion **** \nDid not receive valid response"
    end
  end

  def label_for_filename
    label.parameterize
  end

  def get_next_words(label)
    return if Rails.env.test?
    response = OpenAiClient.new(open_ai_opts).get_next_words(label)
    if response
      next_words = response[:content].gsub("```json", "").gsub("```", "").strip
      # next_words = response[:content]
      if next_words.blank? || next_words.include?("NO NEXT WORDS")
        return
      end

      if valid_json?(next_words)
        next_words = JSON.parse(next_words)
      else
        puts "INVALID JSON: #{next_words}"
        next_words = transform_into_json(next_words)
      end
    else
      Rails.logger.error "*** ERROR - get_next_words *** \nDid not receive valid response. Response: #{response}\n"
    end
    next_words["next_words"]
  end

  def background_color_for(category)
    key = case category.to_s
      when "adjective" then "blue"
      when "verb" then "green"
      when "pronoun" then "yellow"
      when "noun" then "orange"
      when "conjunction" then "white"
      when "preposition", "social" then "pink"
      when "question" then "purple"
      when "adverb" then "brown"
      when "important_function" then "red"
      when "determiner" then "gray"
      else "gray"
      end

    ColorHelper::PRESET_HEX[key]
  end

  def reset_part_of_speech!
    pos = AacWordCategorizer.categorize(label)
    self.update_column(:part_of_speech, pos)
  end

end
