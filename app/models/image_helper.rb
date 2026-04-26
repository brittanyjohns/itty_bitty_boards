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
      PreprocessDocTileVariantJob.perform_async(doc.id)

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

        PreprocessDocTileVariantJob.perform_async(doc.id)
      end

      self.update(status: "finished", src_url: doc.tile_url)
      update_all_boards_image_belongs_to(doc.tile_url)
    rescue => e
      Rails.logger.error "ImageHelper ERROR: #{e.inspect}"
      raise e
    end

    doc
  end

  def create_image(user_id = nil, image_prompt = nil)
    return if Rails.env.test?

    user_id ||= self.user_id

    opts = open_ai_opts
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
      output_format
    )
  end

  def save_image_from_base64(
    b64_json,
    user_id = nil,
    revised_prompt = nil,
    edited_prompt = nil,
    source_type = "OpenAI",
    output_format = "webp"
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

    doc = self.docs.create!(
      raw: raw_txt,
      user_id: user_id,
      processed: revised_prompt,
      source_type: source_type,
      data: {
        b64_json: true,
        output_format: format,
        content_type: content_type,
      },
    )

    doc.image.attach(
      io: StringIO.new(decoded_image),
      filename: "img_#{self.id}_doc_#{doc.id}.#{ext}",
      content_type: content_type,
    )

    # PreprocessDocTileVariantJob.perform_async(doc.id)
    doc.tile_variant.processed

    self.update!(status: "finished")
    update_all_boards_image_belongs_to(doc.tile_url)

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
    prompt = OpenAiClient.new(open_ai_opts).get_image_prompt_suggestion
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

  def clarify_image_description(raw, restaurant_name)
    return if Rails.env.test?
    response, messages_sent = OpenAiClient.new(open_ai_opts).clarify_image_description(raw, restaurant_name)
    begin
      response_text = nil
      response_hash = nil
      if response
        response_text = response[:content].gsub("```json", "").gsub("```", "").strip
        if valid_json?(response_text)
          response_text
        else
          puts "INVALID JSON: #{response_text}"
          response_text = transform_into_json(response_text)
        end
      else
        Rails.logger.error "*** ERROR - clarify_image_description *** \nDid not receive valid response. Response: #{response}\n"
      end

      response_hash = JSON.parse(response_text) if response_text

      if response_hash["menu_items"].blank?
        puts "NO DESCRIPTION"
        return nil
      end
      puts "response_hash: #{response_hash["menu_items"]} "
    rescue => e
      puts "****clarify_image_description--ERROR: #{e.inspect}"
    end

    [response_hash, messages_sent]
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

  def create_image_variation(image_file = nil, user_id = nil)
    return if Rails.env.test?
    success = false
    Rails.logger.debug "Creating image variation for image ID #{self.id}"
    user_id ||= self.user_id
    img_variation_url = OpenAiClient.new(open_ai_opts).create_image_variation(image_file, user_id)
    if img_variation_url
      Rails.logger.debug "Generated image variation URL: #{img_variation_url}"
      save_image(img_variation_url, user_id)
      success = true
    else
      Rails.logger.error "**** ERROR - create_image_variation **** \nDid not receive valid response.\n"
    end
    success
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

  def image_types
    ["Sigma 24mm f/8",
     "Pixel Art",
     "Anime",
     "Digital art",
     "Photography",
     "Sculpture",
     "Printmaking",
     "Graphic design",
     "Ceramic pottery",
     "Glassblowing",
     "Stained glass",
     "Metal sculpture",
     "Street art",
     "Graffiti art",
     "Calligraphy",
     "Pencil drawing",
     "Ink illustration",
     "Cartoon art",
     "Comic book art",
     "Mosaic art",
     "Textile art",
     "Embroidery",
     "Jewelry making",
     "Installation art",
     "Performance art",
     "Video art",
     "Animation",
     "Concept art",
     "Abstract art",
     "Realism art",
     "Impressionism",
     "Surrealism",
     "Pop art",
     "Minimalism",
     "Cubism",
     "Renaissance art",
     "Modern art",
     "Contemporary art"]
  end

  def remove_extras_from_prompt(prompt_text)
    return "" unless prompt_text
    image_types.each do |item|
      art_type = item.downcase
      normalized_prompt_text = prompt_text&.downcase
      prompt_text = normalized_prompt_text&.gsub(art_type, "")&.strip
    end
    prompt_text
  end

  def ask_ai_for_image_prompt
    return if Rails.env.test?
    message = {
      "role": "user",
      "content": create_image_prompt_text,
    }
    begin
      ai_client = OpenAiClient.new({ messages: [message] })
      response = ai_client.create_chat
    rescue => e
      puts "**** ERROR - ask_ai_for_image_prompt **** \n#{e.message}\n"
    end
    if response && response[:role]
      role = response[:role] || "assistant"
      response_content = response[:content]
      self.revised_prompt = response_content
    else
      Rails.logger.debug "*** ERROR - ask_ai_for_image_prompt *** \nDid not receive valid response. Response: #{response}\n"
    end
    response_content
  end

  def create_image_prompt_text
    "Can you create a text prompt for me that I can use with DALL-E to generate an image of 
    a cartoon character expressing a certain emotion or doing a specific action. 
    Or if the word is an object, write a prompt to generate an image of that object in a clear and simple way. 
    Use as much detail as possible in order to generate an image that a child could easily recognize that the image represents this word/phrase: '#{self.label}'.
     Respond with the prompt only, not the image or any other text.  It should be very clear that the word/phrase is '#{self.label}'."
  end

  def gpt_prompt
    ask_ai_for_image_prompt || "Create an image of a cartoon-style individual with medium-length hair, wearing a comfortable shirt. This person should have a facial expression and body language that adapt to the concept of '#{self.label}'. If the word is an object like 'pizza', they could be holding or interacting with it. If it's a place like 'outside', they could be standing with a backdrop that suggests the setting, and if it's an action or emotion, they should be performing a gesture that conveys that action or feeling. The background should be minimalist, using a soft, solid color to keep the main focus on the individual and the concept they are depicting."
  end
end
