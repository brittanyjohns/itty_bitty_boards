require "open-uri"

module ImageHelper
  include UtilHelper

  def name_to_send
    open_ai_opts[:prompt] || name
  end

  def save_image(url, user_id = nil, revised_prompt = nil, edited_prompt = nil, source_type = "OpenAI")
    return if Rails.env.test?
    begin
      downloaded_image = Down.download(url)
      user_id ||= self.user_id
      raw_txt = edited_prompt || name_to_send
      doc = self.docs.create!(raw: raw_txt, user_id: user_id, processed: revised_prompt, source_type: source_type, original_image_url: url)
      extension = doc.extension || "webp"
      doc.image.attach(io: downloaded_image, filename: "img_#{self.id}_doc_#{doc.id}.webp", content_type: "image/webp")
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
      puts "Downloading image from: #{url}"
      downloaded_image = Down.download(url)
      user_id ||= self.user_id
      doc = self.docs.create!(raw: raw_txt, user_id: user_id, processed: processed, source_type: source_type, original_image_url: url)
      doc.image.attach(io: downloaded_image, filename: "img_#{self.id}_doc_#{doc.id}.webp", content_type: file_format) if downloaded_image
      self.update(status: "finished", src_url: url)
      update_all_boards_image_belongs_to(url)
    rescue => e
      puts "ImageHelper ERROR: #{e.inspect}"
      raise e
    end
    doc
  end

  def create_image(user_id = nil)
    return if Rails.env.test?
    user_id ||= self.user_id
    response = OpenAiClient.new(open_ai_opts).create_image
    img_url = response[:img_url]
    revised_prompt = response[:revised_prompt]
    edited_prompt = response[:edited_prompt]
    doc = nil
    if img_url
      doc = save_image(img_url, user_id, revised_prompt, edited_prompt)
    else
      Rails.logger.error "**** ERROR - create_image **** \nDid not receive valid response.\n #{response&.inspect}"
    end
    doc
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

  def create_audio_from_text(text = nil, voice = "alloy", language = "en")
    text = text || self.label
    new_audio_file = nil
    if Rails.env.test?
      return
    end
    response = OpenAiClient.new(open_ai_opts).create_audio_from_text(text, voice, language)
    if response
      # response.stream_to_file("output.aac")
      # audio_file = File.binwrite("audio.mp3", response)
      File.open("output.aac", "wb") { |f| f.write(response) }
      audio_file = File.open("output.aac")
      new_audio_file = save_audio_file(audio_file, voice, language)
      file_exists = File.exist?("output.aac")
      File.delete("output.aac") if file_exists
    else
      Rails.logger.error "**** ERROR - create_audio_from_text **** \nDid not receive valid response.\n #{response&.inspect}"
    end
    new_audio_file
  end

  def save_audio_file(audio_file, voice, language = "en")
    if language == "en"
      self.audio_files.attach(io: audio_file, filename: "#{self.label_for_filename}_#{voice}.aac")
    else
      self.audio_files.attach(io: audio_file, filename: "#{self.label_for_filename}_#{voice}_#{language}.aac")
    end

    new_audio_file = self.audio_files.last
    new_audio_file
  end

  def clarify_image_description(raw)
    return if Rails.env.test?
    response, messages_sent = OpenAiClient.new(open_ai_opts).clarify_image_description(raw)
    Rails.logger.info "clarify_image_description response: #{response}\n messages_sent: #{messages_sent}"
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

  def create_image_variation(img_url = nil, user = nil)
    return if Rails.env.test?
    success = false
    img_url ||= main_doc.main_image_on_disk
    img_variation_url = OpenAiClient.new(open_ai_opts).create_image_variation(img_url)
    if img_variation_url
      save_image(img_variation_url)
      success = true
    else
      Rails.logger.error "**** ERROR - create_image_variation **** \nDid not receive valid response.\n"
    end
    success
  end

  # def valid_json?(json)
  #   JSON.parse(json)
  #   return true
  # rescue JSON::ParserError => e
  #   return false
  # end

  # def transform_into_json(content_str)
  #   json_str = content_str.gsub(/:([a-zA-z_]+)/, '"\1"') # Convert symbols to strings
  #   json_str = json_str.gsub("=>", ": ") # Replace hash rockets with colons

  #   # Now parse the string as JSON
  #   begin
  #     data = JSON.parse(json_str)
  #   rescue JSON::ParserError => e
  #     puts "Error parsing JSON: #{e.message}"
  #     # Handle invalid JSON here
  #   end

  #   # If necessary, convert back to JSON string for output or further processing
  #   json_output = data.to_json
  #   puts "json_output: #{json_output}"
  #   json_output
  # end

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
