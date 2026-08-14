require "openai"

class OpenAiClient
  GTP_MODEL = ENV.fetch("OPENAI_GTP_MODEL", "gpt-4.1-mini")
  GTP_5_MODEL = ENV.fetch("OPENAI_GTP_5_MODEL", "gpt-5-mini")
  QUICK_GTP_MODEL = ENV.fetch("OPENAI_QUICK_GTP_MODEL", "gpt-4.1-nano")
  IMAGE_MODEL = ENV.fetch("OPENAI_IMAGE_MODEL", "gpt-image-1-mini")
  TTS_MODEL = ENV.fetch("OPENAI_TTS_MODEL", "gpt-4o-mini-tts")
  DEFAULT_IMAGE_SIZE = "1024x1024".freeze
  DEFAULT_IMAGE_OUTPUT_FORMAT = "webp".freeze
  # Tiles render at 288px (ApplicationRecord::TILE_VARIANT_TRANSFORMATIONS) and
  # are re-encoded to webp q65, so "high" buys nothing visible and costs real
  # money. Explicit + ENV-tunable so the tier is a decision, not a default.
  DEFAULT_IMAGE_QUALITY = ENV.fetch("OPENAI_IMAGE_QUALITY", "medium").freeze
  # `background: "transparent"` needs an output format with an alpha channel.
  TRANSPARENCY_CAPABLE_FORMATS = %w[png webp].freeze

  def initialize(opts)
    @opts = opts.deep_symbolize_keys
    @messages = @opts[:messages] || []
    @prompt = @opts[:prompt] || "backup"
  end

  # Default request timeout for OpenAI calls. ruby-openai's own default is 120s
  # but several failure modes (TLS half-open, idle keep-alive) can stall longer.
  # Explicit cap prevents a hung OpenAI request from holding a puma thread.
  OPENAI_REQUEST_TIMEOUT_SECONDS = Integer(ENV.fetch("OPENAI_REQUEST_TIMEOUT", 60))

  def self.openai_client
    @openai_client ||= OpenAI::Client.new(
      access_token: ENV.fetch("OPENAI_ACCESS_TOKEN"),
      log_errors: true,
      request_timeout: OPENAI_REQUEST_TIMEOUT_SECONDS,
    )
  end

  def openai_client
    @openai_client ||= OpenAI::Client.new(
      access_token: ENV.fetch("OPENAI_ACCESS_TOKEN"),
      log_errors: true,
      request_timeout: OPENAI_REQUEST_TIMEOUT_SECONDS,
    )
  end

  # Suggests a *subject description* for the user to edit, not a full prompt:
  # Images::PromptBuilder owns the style spec and constraints, and wraps whatever
  # the user ends up submitting. Handing back a full prompt here would produce a
  # doubled, self-contradicting envelope.
  def get_image_prompt_suggestion
    @model = GTP_MODEL
    style_clause = @opts[:style_clause].presence ||
                   Images::PromptBuilder::STYLES[Images::PromptBuilder::DEFAULT_STYLE]

    base_prompt = <<~PROMPT
      Write a short, concrete visual description of what an AAC communication tile
      for the word or phrase "#{@prompt}" should show.

      Describe only the subject: what is pictured, who is doing what, and any detail
      needed so a child recognizes the word at a glance. One or two sentences.
      Do not mention art style, colors, backgrounds, or the absence of text — those
      are applied separately. Respond with the description only.

      For context, the image will be rendered in this style: #{style_clause}
    PROMPT

    @messages = [{
      role: "user",
      content: [{ type: "text", text: base_prompt }],
    }]

    response = create_chat(false)
    response.with_indifferent_access.dig("content")
  end

  def create_image
    return placeholder_image_response if AppEnv.staging?

    client = openai_client

    output_format = normalize_output_format(@opts[:output_format] || DEFAULT_IMAGE_OUTPUT_FORMAT)

    params = {
      model: @opts[:model] || IMAGE_MODEL,
      prompt: @prompt,
      size: DEFAULT_IMAGE_SIZE,
      output_format: output_format,
      quality: @opts[:quality].presence || DEFAULT_IMAGE_QUALITY,
    }

    # AAC tiles sit on colored part-of-speech backgrounds, so real alpha matters.
    # Asking for it in prose alone (which is all we used to do) reliably yields a
    # white box instead.
    if transparent_background_requested? && TRANSPARENCY_CAPABLE_FORMATS.include?(output_format)
      params[:background] = "transparent"
    end

    # optional GPT image params
    params[:moderation] = @opts[:moderation] if @opts[:moderation].present?
    params[:n] = @opts[:n] if @opts[:n].present?
    params[:output_compression] = @opts[:output_compression] if @opts[:output_compression].present?

    response = generate_with_background_fallback(client, params)

    first_image = extract_first_image(response)
    raise "OpenAI image generation returned no image data" if first_image.blank?

    {
      b64_json: first_image[:b64_json],
      img_url: first_image[:url], # likely nil for gpt-image models, but harmless to expose
      revised_prompt: first_image[:revised_prompt],
      edited_prompt: @prompt,
      output_format: params[:output_format],
      content_type: content_type_for(params[:output_format]),
      model: params[:model],
      size: params[:size],
      quality: params[:quality],
      background: params[:background],
      raw_response: response,
    }
  rescue => e
    Rails.logger.error("OpenAiClient#create_image failed: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n")) if e.backtrace
    raise
  end

  # Not every image model accepts `background` — gpt-image-2, for one, rejects
  # `transparent` outright. Rather than pin ourselves to a model, drop the param
  # and retry once so swapping OPENAI_IMAGE_MODEL can't take generation down.
  def generate_with_background_fallback(client, params)
    client.images.generate(parameters: params)
  rescue => e
    raise unless params[:background].present? && background_unsupported_error?(e)

    Rails.logger.warn(
      "OpenAiClient#create_image: model #{params[:model]} rejected background=" \
      "#{params[:background]}; retrying opaque. (#{e.message})"
    )
    params.delete(:background)
    client.images.generate(parameters: params)
  end

  def background_unsupported_error?(error)
    error.message.to_s.downcase.include?("background")
  end

  # Accepts either the explicit opt or the legacy string value ("transparent").
  def transparent_background_requested?
    value = @opts.key?(:transparent) ? @opts[:transparent] : @opts[:background]
    return false if value.nil?

    value.to_s.downcase.in?(%w[true transparent 1])
  end

  def create_audio_from_text(text, voice = "polly:kevin", language = "en", instructions = "")
    return if Rails.env.test?
    if voice.blank?
      voice = "polly:kevin"
    end

    request_params = {
      input: text,
      model: TTS_MODEL,
      voice: voice,
      instructions: instructions,
    }
    if instructions.blank?
      # remove instructions if blank
      request_params.delete(:instructions)
    end

    begin
      response = openai_client.audio.speech(parameters: request_params)
    rescue => e
      Rails.logger.debug "**** ERROR **** \n#{e.message}\n#{e.inspect}"
    end
    Rails.logger.debug "*** ERROR *** Invaild Audio Response: #{response}" unless response
    response
  end

  def translate_text(text, source_language, target_language)
    return if Rails.env.test?
    Rails.logger.debug "FROM OpenAiClient: text: #{text} -- target_language: #{target_language}"
    begin
      translation_prompt = "Translate the following text from #{source_language} to #{target_language}:\n #{text}
      Respond with the JSON object in the following format: {\"translation\": \"translated text\"}"

      @model = GTP_MODEL
      @messages = [{ role: "user", content: [{ type: "text", text: translation_prompt }] }]
      response = create_chat
      translated_text = nil
      if response
        response = response.with_indifferent_access
        translated_data = JSON.parse(response[:content]) if response[:content]
        translated_text = translated_data["translation"] if translated_data
      else
        Rails.logger.debug "**** ERROR **** \nDid not receive valid response.\n"
      end
    rescue => e
      Rails.logger.debug "**** ERROR **** \n#{e.message}\n#{e.inspect}"
    end
    Rails.logger.debug "*** ERROR *** Invaild Translation Response: #{response}" unless response
    translated_text
  end

  GPT_VISION_MODEL = "gpt-4o-mini"

  def describe_image(img_url)
    begin
      response = openai_client.chat(parameters: {
                                      model: GPT_VISION_MODEL,
                                      messages: [{ role: "user",
                                                  content: [{ type: "text",
                                                              text: "Please describe the content of this image in detail. Provide a clear and concise description that captures the main elements and context of the image." },
                                                            { type: "image_url", image_url: { url: img_url } }] }],
                                    })
      Rails.logger.debug "*** ERROR *** Invaild Image Description Response: #{response}" unless response
      response
    rescue => e
      Rails.logger.error "OpenAI Error describing image: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      nil
    end
  end

  def generate_formatted_board(name, num_of_columns, words = [], max_num_of_rows = 4, maintain_existing = false)
    @model = GTP_MODEL
    Rails.logger.debug "generate_formatted_board - model: #{@model} -- name: #{name} -- num_of_columns: #{num_of_columns} -- words: #{words.count} -- max_num_of_rows: #{max_num_of_rows}"
    @messages = [{ role: "user",
                  content: [{ type: "text",
                              text: format_board_prompt(name, num_of_columns, words, max_num_of_rows, maintain_existing) }] }]
    response = create_completion
    Rails.logger.debug "*** ERROR *** Invaild Formatted Board Response: #{response}" unless response
    response[:content] if response
  end

  # def categorize_word(word)
  #   @model = QUICK_GTP_MODEL
  #   @messages = [{ role: "user",
  #                 content: [{ type: "text",
  #                             text: "Categorize the word '#{word}' into one of the following parts of speech: #{Image.valid_parts_of_speech} If the word can be used as multiple parts of speech, choose the most common one. If the word is not a part of speech, respond with 'other'. Respond as json. Example: {\"part_of_speech\": \"noun\"}" }] }]
  #   response = create_chat
  #   Rails.logger.debug "*** ERROR *** Invaild Categorize Word Response: #{response}" unless response
  #   response
  # end

  AAC_OVERRIDES = {
    "more" => "social",
    "again" => "social",
    "finished" => "social",
    "all done" => "social",
    "yes" => "social",
    "no" => "important_function",
    "not" => "important_function",
    "don't" => "important_function",
    "this" => "determiner",
    "that" => "determiner",
    "here" => "determiner",
    "there" => "determiner",
  }.freeze

  AAC_PHRASE_OVERRIDES = {
    "excuse me" => "social",
    "thank you" => "social",
    "all done" => "social",
  }.freeze

  def categorize_word(word)
    normalized = word.to_s.downcase.strip
    normalized = normalized.gsub(/\s+/, " ")

    if AAC_PHRASE_OVERRIDES.key?(normalized)
      return({ "part_of_speech" => AAC_PHRASE_OVERRIDES[normalized] }.to_json)
    end

    # then single-word overrides, then GPT fallback...
  end

  def gpt_categorize(input)
    @model = QUICK_GTP_MODEL
    safe = input.to_s.strip

    @messages = [
      {
        role: "system",
        content: <<~TEXT,
          You categorize AAC words/phrases into exactly ONE category.
          Output MUST be valid JSON with EXACTLY this schema:
          {"part_of_speech":"adjective|verb|pronoun|noun|conjunction|preposition|social|question|adverb|important_function|determiner|default"}
          No other keys. No explanations. No multiple fields.
          If input has multiple words, categorize the whole phrase as one category (usually social or default).
        TEXT
      },
      {
        role: "user",
        content: "Input: #{safe.inspect}\nReturn JSON only.",
      },
    ]

    create_chat
  end

  def next_words_prompt(label)
    "Given a specific context or emotion, such as '#{label}', 
    provide a list of 24 foundational words or short phrases (2 words max) that are crucial for basic communication in an AAC (Augmentative and Alternative Communication) device. 
    These words should be broadly applicable, supporting users in expressing a variety of intents, needs, and responses across different situations.
    Determine if the word '#{label}' typically leads to specific follow-up words in everyday communication. If not, respond with 'NO NEXT WORDS'. 
    This will help in populating an AAC (Augmentative and Alternative Communication) device with contextually appropriate vocabulary.
    Don't include contractions or words that are too specific to a particular context. Two-word phrases are acceptable but should be kept to a minimum.
    The goal is to populate an AAC device with versatile vocabulary. '#{label}' shoule not be included in the list of next words or phrases.
    Make your best attempt to provide a list of 24 words or short phrases (2 words max) that are foundational for basic communication in an AAC device. Respond with 'NO NEXT WORDS' if there are no common follow-up words for '#{label}' that would be used in conversation & an AAC device. Use json format. Respond with a JSON object in the following format: {\"next_words\": [\"word1\", \"word2\", \"word3\", ...]}"
  end

  def maintain_existing_instructions(existing_grid)
    "The existing grid layout is as follows: #{existing_grid}. Please maintain the existing size of each word, changing only the position of the words as needed.
    Give priority to the words with the 'board_type' of 'category' when placing them on the grid. If the word is a 'category' word, it should be placed in the top or around top side of the grid."
  end

  def format_board_prompt(name, num_of_columns, existing_grid = [], max_num_of_rows = 4, maintain_existing = false)
    words = existing_grid.map { |word_obj| word_obj[:word] }

    Rails.logger.debug "\nName: #{name} -- Num of Columns: #{num_of_columns} -- Max Num of Rows: #{max_num_of_rows} -- Existing Grid: #{existing_grid.count} -- Maintain Existing: #{maintain_existing}"
    word_str = words.join(", ") unless words.blank?
    word_count = words.size
    text = <<-PROMPT
      Create an AAC communication board formatted as a grid layout.

      Organize the words based on these guidelines:
      1. Core words should be placed first and grouped together, prioritizing high-frequency words - Stating with the coordinate [0,0].
      2. Group words by parts of speech (e.g., pronouns, verbs, adjectives).
      3. Consider how speech-language pathologists arrange words for ease of use in communication, ensuring frequently used words are near the top left.
      4. Use a grid layout with a MAXIMUM of #{num_of_columns} columns and MAX rows: #{max_num_of_rows}.
      5. Each entry should include the word, its grid position as [x, y], its part of speech, its size, and its frequency of use.
      6. The size of each word should be based on its frequency of use, with high-frequency words being larger. Size is represented as number of grid spaces the word occupies. [1,1] is a single grid space. [2,2] is a 2x2 grid space. & so on.
      7. Do not overlap words or exceed the grid size.
      #{maintain_existing_instructions(existing_grid) if maintain_existing}

      Please create a grid layout that include the words: '#{words}', grouped and positioned based on their typical use in AAC communication.
      It is VERY important that the Y-COOORDINATE should not exceed #{max_num_of_rows} and the X-COORDINATE should not exceed #{num_of_columns}.
             Please respond as a valid JSON object with the following structure:

      {
        "grid": [
          {"word": "I", "position": [0,0], "part_of_speech": "pronoun", "frequency": "medium", "size": [1,1]},
          {"word": "banana", "position": [0,1], "part_of_speech": "noun", "frequency": "low", "size": [1,1]},
          {"word": "more", "position": [2,4], "part_of_speech": "adverb", "frequency": "high", "size": [1,1]},
          ...
          {"word": "elevator", "position": [5,10], "part_of_speech": "noun", "frequency": "low", "size": [1,1]}
        ],
              }
    PROMPT
  end

  def explanation_prompt
    'Please also provide a professional explanation (for a speech-language pathologist) and a personable explanation (for a caregiver or user - but still professional) of the layout.
    {"professional_explanation": "This layout is designed to help users quickly find and use the most common words in AAC communication. The words are grouped by parts of speech and arranged in a grid to make it easy to locate and select the right word.
    "personable_explanation": "This board is set up to help you find the words you need to communicate quickly and easily. The words are grouped by type and placed in a grid so you can find them easily.}'
  end

  def get_next_words(label)
    @model = GTP_MODEL
    @messages = [{ role: "user",
                  content: [{
      type: "text",
      text: next_words_prompt(label),
    }] }]
    response = create_chat
    Rails.logger.debug "*** ERROR *** Invaild Next Words Response: #{response}" unless response
    response
  end

  LONG_LANGUAGE_NAMES = { 'en': "English",
                          'es': "Spanish",
                          'fr': "French",
                          'de': "German",
                          'it': "Italian",
                          'pt': "Portuguese",
                          'nl': "Dutch",
                          'ru': "Russian",
                          'ja': "Japanese",
                          'ko': "Korean",
                          'zh': "Chinese",
                          'ar': "Arabic",
                          'hi': "Hindi",
                          'tr': "Turkish",
                          'vi': "Vietnamese",
                          'pl': "Polish",
                          'th': "Thai" }.freeze

  # Appends a "Respond in <language>" instruction when `language` is a supported
  # non-English code. No-op for `en`, blank, or unknown codes, so English
  # callers produce exactly the same prompt as before.
  def append_language_instruction(text, language)
    lang = language.to_s.strip.downcase
    return text if lang.blank? || lang == "en"

    formatted_language = LONG_LANGUAGE_NAMES[lang.to_sym]
    return text if formatted_language.blank?

    "#{text} Respond in #{formatted_language}."
  end

  def get_words_for_scenario(scenario_description, number_of_words = 24, language = "en", profile: nil)
    prompt = <<~PROMPT
      I have a scenario description: "#{scenario_description}".

      Please provide #{number_of_words} words that are foundational for basic communication in an AAC device.
      These words should relate to the context of the scenario and be broadly applicable, supporting users in expressing a variety of intents, needs, and responses across different situations.
      Do not repeat any words that are already on the board & only provide #{number_of_words} words.
      Respond with a JSON object in the following format: {\"words\": [\"word1\", \"word2\", \"word3\", ...]}
    PROMPT
    prompt = append_language_instruction(prompt, language)
    prompt = append_profile_guidance(prompt, profile)

    @model = GTP_MODEL
    @messages = [{ role: "user",
                   content: [{ type: "text", text: prompt }] }]
    response = create_chat
    Rails.logger.debug "*** ERROR *** Invaild Words for Scenario Response: #{response}" unless response
    Rails.logger.debug "Words for Scenario Response: #{response.inspect}"
    response
  end

  def get_additional_words(board, name, number_of_words = 24, exclude_words = [], use_preview_model = false, language = "en", profile: nil)
    exclude_words_prompt = exclude_words.blank? ? "and no words to exclude." : "excluding the words '#{exclude_words.join("', '")}'."

    text = ""
    if board&.dynamic?
      Rails.logger.debug "** Dynamic Board"
      first_sentence = "I have the initial communication board displayed to the user."
      word_instructions = " #{first_sentence} with the current words: [#{exclude_words_prompt}]. Please provide EXACTLY #{number_of_words} additional words that are foundational for basic communication in an AAC device."
      static_instructions = "These words should be broadly applicable, supporting users in expressing a variety of intents, needs, and responses across different situations. They should be similar in nature to the words already on the board, but not duplicates."
      text = "#{word_instructions} #{static_instructions}"
      ending = "Use the existing words on the board as a guide for the type of words that should be added. Respond with a JSON object in the following format: {\"additional_words\": [\"word1\", \"word2\", \"word3\", ...]}"
    elsif board&.static?
      Rails.logger.debug "** Static Board"
      first_sentence = "I have an existing AAC board titled, '#{name}'"
      word_instructions = " #{first_sentence} with the current words: [#{exclude_words_prompt}]. Please provide EXACTLY #{number_of_words} additional words that are foundational for basic communication in an AAC device."
      static_instructions = "These words should be broadly applicable, supporting users in expressing a variety of intents, needs, and responses across different situations. They should be similar in nature to the words already on the board, but not duplicates."
      text = "#{word_instructions} #{static_instructions}"
      ending = "If the board is 'drink', words like 'water', 'milk', 'juice', etc. would be appropriate.
        If the board is 'go to', words like 'home', 'school', 'store', 'park', etc. would be appropriate.
        If the board is 'feelings', words like 'happy', 'sad', 'angry', 'tired', etc. would be appropriate.
        Use the existing words on the board as a guide for the type of words that should be added. Respond with a JSON object in the following format: {\"additional_words\": [\"word1\", \"word2\", \"word3\", ...]}"
    elsif board&.predictive?
      Rails.logger.debug "** Predictive Board"
      text = "I have an AAC board & the last word/phrase selected was '#{name}'. Please provide #{number_of_words} words/phrases that are most likely to be used next in conversation after the word/phrase '#{name}'."
      ending = "If the board is 'go to', words like 'home', 'school', 'store', 'park', etc. would be appropriate. 
        If the board is 'we', words like 'are', 'can', 'will', etc. would be appropriate.
        If the board is 'will', words like 'you', 'go', 'eat', etc. would be appropriate.
        Respond with a JSON object in the following format: {\"additional_words\": [\"word1\", \"word2\", \"word3\", ...]}"
    elsif board&.category?
      Rails.logger.debug "** Category Board"
      text = "I have an AAC button labeled '#{name}'. Please provide #{number_of_words} words that are related to the category '#{name}'."
      ending = "If the board is 'feeling', words like 'happy', 'sad', 'angry', 'tired', etc. would be appropriate.
        If the board is 'drink', words like 'water', 'milk', 'juice', etc. would be appropriate.
        If the board is 'food', words like 'apple', 'banana', 'cookie', etc. would be appropriate."
    end
    format_instructions = "Do not repeat any words that are already on the board & only provide #{number_of_words} words. DO NOT INCLUDE [#{exclude_words_prompt}]. Respond with a JSON object in the following format: {\"additional_words\": [\"word1\", \"word2\", \"word3\", ...]}"
    format_instructions = append_language_instruction(format_instructions, language)
    text = "#{text} #{format_instructions} #{ending}"
    text = append_profile_guidance(text, profile)
    @messages = [{ role: "user",
                  content: [{
      type: "text",
      text: text,
    }] }]

    @model = GTP_MODEL
    response = create_chat
    Rails.logger.debug "*** ERROR *** Invaild Additional Words Response: #{response}" unless response
    response
  end

  def get_word_suggestions(name, number_of_words = 24, words_to_exclude = [], board_type = "default", language: "en", profile: nil)
    if words_to_exclude.is_a?(String)
      words_to_exclude = words_to_exclude.split(",").map(&:strip)
    end
    @model = GTP_MODEL
    if board_type == "menu"
      text = "I have a restaurant menu titled, '#{name}'. Inferring the context from the name AND the existing items on the menu, please provide #{number_of_words} additional menu items that are commonly found on restaurant menus. Please make them lowercase with the exception of proper nouns, sentences, etc. that should be capitalized."
    else
      text = "I have an AAC board titled, '#{name}'. Inferring the context from the name AND the existing words on the board, please provide #{number_of_words} words. Please make them lowercase with the exception of proper nouns, sentences, etc. that should be capitalized."
    end
    unless words_to_exclude.blank?
      text += " Do not repeat any words that are already on the board & only provide #{number_of_words} words. The words currently on the board are '#{words_to_exclude.join("', '")}'."
    end
    format_instructions = "Respond with a JSON object in the following format: {\"words\": [\"word1\", \"word2\", \"word3\", ...]}"
    text += format_instructions
    text = append_language_instruction(text, language)
    text = append_profile_guidance(text, profile)
    @messages = [{ role: "user",
                  content: [{ type: "text",
                              text: text }] }]

    response = create_chat
    response
  end

  def get_social_story_word_suggestions(name, number_of_steps, max_number_of_words, words_to_exclude = [], language: "en")
    if words_to_exclude.is_a?(String)
      words_to_exclude = words_to_exclude.split(",").map(&:strip)
    end

    words_to_exclude = Array(words_to_exclude)
      .map { |w| w.to_s.strip.downcase }
      .reject(&:blank?)

    @model = GTP_MODEL
    Rails.logger.debug "User - model: #{@model} -- name: #{name} -- number_of_steps: #{number_of_steps} -- max_number_of_words: #{max_number_of_words} -- words_to_exclude: #{words_to_exclude.inspect}"

    min_number_of_words = 2
    text = <<~TEXT
                                                                                                            I am creating a social story titled "#{name}".

    Please generate #{number_of_steps} SHORT step instructions that could appear on tiles in a social story AAC board.

    These should represent actions or steps in the story.

    Requirements:
    - each item should be a short instruction or step (#{min_number_of_words}-#{max_number_of_words} words)
    - simple language appropriate for children
    - represent a sequence of events in the story
    - avoid long sentences
    - avoid punctuation
    - lowercase only (except for proper nouns if necessary)
    - no duplicates
    TEXT

    unless words_to_exclude.blank?
      text += <<~TEXT

        Do not include any items already in this list:
        #{words_to_exclude.to_json}
      TEXT
    end

    text += <<~TEXT

      Respond ONLY with valid JSON in this format:
      {"words": ["step one example", "next step example", "another step example"]}
    TEXT

    text = append_language_instruction(text, language)

    @messages = [{
      role: "user",
      content: [{ type: "text", text: text }],
    }]

    create_chat
  end

  def get_word_suggestions_from_prompt(prompt, language: "en", profile: nil)
    @model = GTP_MODEL
    text = prompt
    format_instructions = "Respond with a JSON object in the following format: {\"words\": [\"word or phrase 1\", \"word or phrase 2\", \"word or phrase 3\", ...]}. Use spaces between words in a phrase, never underscores."
    text += format_instructions
    text = append_language_instruction(text, language)
    text = append_profile_guidance(text, profile)
    @messages = [{ role: "user",
                  content: [{ type: "text",
                              text: text }] }]

    create_chat
  end

  # Appends communicator-profile guidance (age / AAC level / vocab type) to a
  # word-suggestion prompt. No-op when `profile` is nil or blank, so callers
  # without a profile produce exactly the same prompt as before.
  def append_profile_guidance(text, profile)
    return text if profile.nil? || profile.blank?

    guidance = profile.prompt_guidance
    return text if guidance.blank?

    "#{text}\n\nCommunicator context: #{guidance}"
  end

  def get_board_description(board)
    name = board.name
    grid_info = board.grid_info
    word_tree = board.word_tree

    @model = GTP_MODEL
    text = <<~TEXT
      I have an AAC board titled, "#{name}". This board is designed to help users communicate effectively using a structured grid layout. 
  
      **Board Details:**
      - Grid sizes: #{grid_info}
      - The board includes a variety of core and fringe vocabulary words but do not list them in the description.
      - Word Tree with predictive words for the dynamic buttons:
      \n #{word_tree} 
      \n

      With the information provided, please provide a brief description of the board, including its purpose, target audience, and layout rationale.

      
      **Instructions:**
      - Provide a **concise, well-structured HTML response** describing the board's **purpose, target audience (age/experience level), and layout rationale**.
      - Use **clear, easy-to-read language**.
      - **Do not list the words** on the board.
      - Format the response using **semantic HTML**, including `<h2>` for headings, `<p>` for descriptions, and `<ul>` for lists.
      
      **Example Output Format:**
      ```html
      <div class="aac-board-info">
        <h2>Purpose</h2>
        <p>This AAC board is designed to support communication in <strong>[specific scenario, e.g., daily routines, school, social interactions]</strong>. It helps users express their needs, emotions, and actions efficiently.</p>
      
        <h2>Target Audience</h2>
        <p>Ideal for <strong>[age/experience level, e.g., young children, beginners, or individuals with communication challenges]</strong>. The board provides a structured way to engage in conversation.</p>
      
        <h2>Grid Layout & Design</h2>
        <ul>
          <li><strong>Grid Size:</strong> Optimized for #{grid_info}, ensuring accessibility on different screen sizes.</li>
          <li><strong>Core & Fringe Vocabulary:</strong> Includes essential words for flexibility while incorporating context-specific words for richer communication.</li>
          <li><strong>Intuitive Placement:</strong> Words are arranged to promote quick selection and ease of use.</li>
        </ul>
      </div>
      ```
    TEXT

    @messages = [{ role: "user",
                  content: [{
      type: "text",
      text: text,
    }] }]
    response = create_chat(false)
    Rails.logger.debug "*** ERROR *** Invalid board description Response: #{response}" unless response
    response
  end

  def save_response_locally(response)
    Rails.logger.debug "*** ERROR *** Invaild Image Description Response: #{response}" unless response
    File.open("response.json", "w") { |f| f.write(response) }
  end

  def create_chat(format_json = true)
    @model ||= GTP_MODEL
    Rails.logger.debug "**** ERROR **** \nNo messages provided.\n" unless @messages
    opts = {
      model: @model, # Required.
      messages: @messages, # Required.
    # temperature: 0.7,
    # response_format: { type: "json_object" },
    }
    if format_json
      opts[:response_format] = { type: "json_object" }
    end
    # Opt-in only, same shape as create_completion: every existing caller sends
    # nothing and keeps the provider default it has always had.
    opts[:temperature] = @opts[:temperature] if @opts[:temperature].present?
    begin
      response = openai_client.chat(
        parameters: opts,
      )
    rescue => e
      Rails.logger.debug "**** ERROR **** \n#{e.message}\n"
    end
    if response
      @role = response.dig("choices", 0, "message", "role")
      @content = response.dig("choices", 0, "message", "content")
    else
      Rails.logger.debug "**** ERROR - create_chat **** \nDid not receive valid response.\n #{response&.inspect}"
    end
    { role: @role, content: @content }
  end

  def create_completion
    @model ||= GTP_MODEL
    Rails.logger.error "**** ERROR **** \nNo messages provided.\n" unless @messages
    opts = {
      model: @model, # Required.
      messages: @messages, # Required.
    }
    opts[:response_format] = @opts[:response_format] if @opts[:response_format].present?
    opts[:temperature] = @opts[:temperature] if @opts[:temperature].present?
    begin
      response = openai_client.chat(
        parameters: opts,
      )
    rescue => e
      Rails.logger.debug "**** ERROR **** \n#{e.message}\n#response: #{response.inspect}"
    end
    if response
      @role = response.dig("choices", 0, "message", "role")
      @content = response.dig("choices", 0, "message", "content")
    else
      Rails.logger.debug "**** ERROR - create_completion **** \nDid not receive valid response.\n #{response&.inspect}"
    end
    { role: @role, content: @content }
  end

  def self.ai_models
    @models = openai_client.models.list
  end

  def extract_first_image(response)
    data = if response.respond_to?(:data)
        response.data
      elsif response.is_a?(Hash)
        response[:data] || response["data"]
      end

    first = data&.first
    return nil if first.blank?

    if first.is_a?(Hash)
      {
        b64_json: first[:b64_json] || first["b64_json"],
        url: first[:url] || first["url"],
        revised_prompt: first[:revised_prompt] || first["revised_prompt"],
      }
    else
      {
        b64_json: first.respond_to?(:b64_json) ? first.b64_json : nil,
        url: first.respond_to?(:url) ? first.url : nil,
        revised_prompt: first.respond_to?(:revised_prompt) ? first.revised_prompt : nil,
      }
    end
  end

  def normalize_output_format(format)
    value = format.to_s.downcase
    return value if %w[png jpeg webp].include?(value)

    DEFAULT_IMAGE_OUTPUT_FORMAT
  end

  def content_type_for(format)
    case format
    when "png"
      "image/png"
    when "jpeg"
      "image/jpeg"
    when "webp"
      "image/webp"
    else
      "image/webp"
    end
  end

  # Staging stub: skip the paid OpenAI image API and return the bundled
  # placeholder so the rest of the image pipeline still runs.
  def placeholder_image_response
    {
      b64_json: Base64.strict_encode64(File.binread(placeholder_image_path)),
      img_url: nil,
      revised_prompt: nil,
      edited_prompt: @opts[:prompt],
      output_format: "jpeg",
      content_type: "image/jpeg",
      model: "staging-placeholder",
      size: DEFAULT_IMAGE_SIZE,
      quality: nil,
      background: nil,
      raw_response: nil,
    }
  end

  def placeholder_image_path
    Rails.root.join("public/placeholder.jpeg")
  end
end
