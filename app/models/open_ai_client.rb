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

  # `request_timeout` is a CLIENT option in ruby-openai, not a chat parameter,
  # so a caller that needs longer than the 60s default has to say so here.
  # Opt-in: every existing caller sends nothing and keeps the default.
  def openai_client
    @openai_client ||= OpenAI::Client.new(
      access_token: ENV.fetch("OPENAI_ACCESS_TOKEN"),
      log_errors: true,
      request_timeout: @opts[:request_timeout].presence || OPENAI_REQUEST_TIMEOUT_SECONDS,
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

  def next_words_prompt(label)
    <<~PROMPT
      The last word or phrase a communicator selected was "#{label}".

      Give 24 words or short phrases (2 words max) that are most likely to be
      selected NEXT, so they can keep building what they are saying. Prefer
      words that can continue many different sentences over ones that only fit
      this topic. Do not include contractions. "#{label}" must not appear in the
      list.

      Some words do not lead anywhere in particular. If "#{label}" has no common
      follow-on words, return an empty array rather than padding the list.

      Respond with a JSON object in the following format:
      {"next_words": ["word1", "word2", "word3", ...]}
    PROMPT
  end

  def get_next_words(label)
    @model = GTP_MODEL
    response = aac_word_chat(next_words_prompt(label), response_key: "next_words",
                                                       schema_name: "aac_next_words")
    Rails.logger.debug "*** ERROR *** Invalid Next Words Response" if response[:content].blank?
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

  # Word selection is a counting exercise as much as a creative one — "exactly
  # N words, no duplicates, include a way to refuse" — and the provider default
  # wanders on all three. Same value and same reasoning as
  # Boards::AdminBuilder::Drafting::TEMPERATURE. Set to "" to send none.
  WORD_SUGGESTION_TEMPERATURE = ENV.fetch("OPENAI_WORD_TEMPERATURE", "0.4").freeze

  # The system message every word-suggestion prompt now carries: who is
  # choosing the words, and what makes one earn a cell. Built once rather than
  # per call — it is the same string for all of them.
  WORD_SUGGESTION_SYSTEM_PROMPT = <<~PROMPT.freeze
    #{Prompts::Aac::WORD_LIST_SYSTEM_PROMPT}
    Word selection rules:
    #{Prompts::Aac::WORD_RULES}
  PROMPT

  # The same kernel for a prompt that ADDS words to a board that already exists.
  #
  # Built per call rather than frozen once, because which rules apply depends on
  # what the board is already holding: `Prompts::Aac.incremental_word_rules`
  # drops the whole-board coverage rules and puts the objection/redirect ask
  # back only when the existing tiles can't already object and redirect.
  def self.incremental_word_system_prompt(existing_words: [])
    <<~PROMPT
      #{Prompts::Aac::WORD_LIST_SYSTEM_PROMPT}
      Word selection rules:
      #{Prompts::Aac.incremental_word_rules(existing_words: existing_words)}
    PROMPT
  end

  # Sends a word-suggestion prompt with the shared AAC kernel in the system
  # slot and a Structured Outputs schema pinning the response key.
  #
  # These prompts used to be a single user message with no persona and no
  # rules, so the model was asked for a topical vocabulary list — the exact
  # failure Prompts::Aac::WORD_LIST_SYSTEM_PROMPT names.
  #
  # Retries once without the schema for the same reason Drafting does: not
  # every model accepts a json_schema, `create_chat` swallows an API error into
  # nil content, and a rejected parameter is otherwise indistinguishable from
  # "the model had nothing to say".
  # `system_prompt:` is selectable because not every list is a vocabulary list.
  # Social-story steps are a sequence of instructions, where WORD_RULES ("no
  # near-duplicates", "include a way to refuse") would actively fight the task —
  # those callers pass the persona alone.
  def aac_word_chat(text, response_key:, schema_name: "aac_word_list",
                    system_prompt: WORD_SUGGESTION_SYSTEM_PROMPT)
    @messages = [
      { role: "system", content: system_prompt },
      { role: "user", content: text },
    ]
    if @opts[:temperature].blank? && WORD_SUGGESTION_TEMPERATURE.present?
      @opts[:temperature] = WORD_SUGGESTION_TEMPERATURE.to_f
    end

    schema = Prompts::Aac.word_list_schema(key: response_key, name: schema_name)
    @opts[:response_format] = { type: "json_schema", json_schema: schema }
    result = create_chat
    return result if result[:content].present?

    Rails.logger.warn("[OpenAiClient] no content from #{@model} with a json schema — retrying without it")
    @opts.delete(:response_format)
    result = create_chat
    return result if result[:content].present?

    # Last rung: drop the temperature too. Both parameters are ENV-tunable, so
    # either can be rejected by a model the value was never checked against —
    # and create_chat turns any 400 into nil content, so a rejected parameter
    # is indistinguishable from an empty answer. Without this rung a bad
    # temperature takes every word suggestion in the app down, which is exactly
    # what it did. Same ladder as AdminBuilder::Drafting.
    return result if @opts[:temperature].blank?

    Rails.logger.warn("[OpenAiClient] no content from #{@model} at temperature " \
                      "#{@opts[:temperature]} — retrying without it")
    @opts.delete(:temperature)
    create_chat
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
    response = aac_word_chat(prompt, response_key: "words", schema_name: "aac_scenario_words")
    Rails.logger.debug "*** ERROR *** Invalid Words for Scenario Response" if response[:content].blank?
    response
  end

  def get_additional_words(board, name, number_of_words = 24, exclude_words = [], use_preview_model = false, language = "en", profile: nil)
    # A bare list, not a sentence. This used to be a full sentence ("and no
    # words to exclude.") that was then nested inside three other sentences,
    # so with nothing to exclude the model was told, literally,
    # "DO NOT INCLUDE [and no words to exclude.]".
    existing_words = Array(exclude_words).map { |w| w.to_s.strip }.reject(&:blank?)
    existing_words_list = existing_words.blank? ? "none yet" : existing_words.join(", ")

    text = ""
    if board&.dynamic?
      Rails.logger.debug "** Dynamic Board"
      first_sentence = "I have the initial communication board displayed to the user."
      word_instructions = " #{first_sentence} with the current words: [#{existing_words_list}]. Please provide EXACTLY #{number_of_words} additional words that are foundational for basic communication in an AAC device."
      static_instructions = "These words should be broadly applicable, supporting users in expressing a variety of intents, needs, and responses across different situations. They should be similar in nature to the words already on the board, but not duplicates."
      text = "#{word_instructions} #{static_instructions}"
      ending = "Use the existing words on the board as a guide for the type of words that should be added."
    elsif board&.static?
      Rails.logger.debug "** Static Board"
      first_sentence = "I have an existing AAC board titled, '#{name}'"
      word_instructions = " #{first_sentence} with the current words: [#{existing_words_list}]. Please provide EXACTLY #{number_of_words} additional words that are foundational for basic communication in an AAC device."
      static_instructions = "These words should be broadly applicable, supporting users in expressing a variety of intents, needs, and responses across different situations. They should be similar in nature to the words already on the board, but not duplicates."
      text = "#{word_instructions} #{static_instructions}"
      ending = "If the board is 'drink', words like 'water', 'milk', 'juice', etc. would be appropriate.
        If the board is 'go to', words like 'home', 'school', 'store', 'park', etc. would be appropriate.
        If the board is 'feelings', words like 'happy', 'sad', 'angry', 'tired', etc. would be appropriate.
        Use the existing words on the board as a guide for the type of words that should be added."
    elsif board&.predictive?
      Rails.logger.debug "** Predictive Board"
      text = "I have an AAC board & the last word/phrase selected was '#{name}'. Please provide #{number_of_words} words/phrases that are most likely to be used next in conversation after the word/phrase '#{name}'."
      ending = "If the board is 'go to', words like 'home', 'school', 'store', 'park', etc. would be appropriate. 
        If the board is 'we', words like 'are', 'can', 'will', etc. would be appropriate.
        If the board is 'will', words like 'you', 'go', 'eat', etc. would be appropriate."
    elsif board&.category?
      Rails.logger.debug "** Category Board"
      text = "I have an AAC button labeled '#{name}'. Please provide #{number_of_words} words that are related to the category '#{name}'."
      ending = "If the board is 'feeling', words like 'happy', 'sad', 'angry', 'tired', etc. would be appropriate.
        If the board is 'drink', words like 'water', 'milk', 'juice', etc. would be appropriate.
        If the board is 'food', words like 'apple', 'banana', 'cookie', etc. would be appropriate."
    end
    format_instructions = "Provide exactly #{number_of_words} words, with no duplicates."
    if existing_words.present?
      format_instructions += " None of them may be a word already on the board. Do not include any of: #{existing_words_list}."
    end
    format_instructions += " Respond with a JSON object in the following format: {\"additional_words\": [\"word1\", \"word2\", \"word3\", ...]}"
    format_instructions = append_language_instruction(format_instructions, language)
    text = "#{text} #{format_instructions} #{ending}"
    text = append_profile_guidance(text, profile)

    @model = GTP_MODEL
    response = aac_word_chat(text, response_key: "additional_words", schema_name: "aac_additional_words")
    Rails.logger.debug "*** ERROR *** Invalid Additional Words Response" if response[:content].blank?
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

    # Persona only, no WORD_RULES: these are ordered story steps, not a
    # vocabulary list, and the selection rules would pull against the sequence.
    aac_word_chat(text, response_key: "words", schema_name: "aac_social_story_steps",
                        system_prompt: Prompts::Aac::WORD_LIST_SYSTEM_PROMPT)
  end

  # `existing_words` is what the board already holds. It selects the system
  # prompt (see .incremental_word_system_prompt) — it is NOT the exclusion list,
  # which the caller has already written into `prompt`.
  def get_word_suggestions_from_prompt(prompt, language: "en", profile: nil, existing_words: [])
    @model = GTP_MODEL
    text = prompt
    format_instructions = "Respond with a JSON object in the following format: {\"words\": [\"word or phrase 1\", \"word or phrase 2\", \"word or phrase 3\", ...]}. Use spaces between words in a phrase, never underscores."
    text += format_instructions
    text = append_language_instruction(text, language)
    text = append_profile_guidance(text, profile)

    aac_word_chat(text, response_key: "words", schema_name: "aac_prompt_words",
                        system_prompt: self.class.incremental_word_system_prompt(existing_words: existing_words))
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

  def create_chat(format_json = true)
    # `model:` used to be accepted and silently ignored — @model was only ever
    # set by instance_variable_set or by a method on this class, so a caller
    # that passed `model:` got GTP_MODEL and no warning. AacWordCategorizer
    # asked for gpt-4o-mini that way for months and never got it.
    @model ||= @opts[:model].presence || GTP_MODEL
    Rails.logger.debug "**** ERROR **** \nNo messages provided.\n" unless @messages
    opts = {
      model: @model, # Required.
      messages: @messages, # Required.
    # temperature: 0.7,
    # response_format: { type: "json_object" },
    }
    # An explicit response_format wins over the `format_json` flag, same shape as
    # create_completion: a caller that has a json_schema wants THAT schema, not
    # the blanket json_object the flag asks for. Every existing caller sends
    # nothing and keeps the behaviour it has always had.
    if @opts[:response_format].present?
      opts[:response_format] = @opts[:response_format]
    elsif format_json
      opts[:response_format] = { type: "json_object" }
    end
    # Opt-in only, same shape as create_completion: every existing caller sends
    # nothing and keeps the provider default it has always had.
    # to_f, always. Every temperature in this app is ENV-tunable and ENV values
    # are Strings, so an un-coerced one reaches the API as "0.4" and is rejected
    # with a 400 — which this method then swallows into nil content, making a
    # type error look exactly like "the model had nothing to say".
    opts[:temperature] = @opts[:temperature].to_f if @opts[:temperature].present?
    # Reasoning models (gpt-5, o-series) spend as long thinking as the effort
    # asks for; a caller on a request-cycle timeout needs to be able to turn
    # that down. Ignored by non-reasoning models' callers, who never send it.
    opts[:reasoning_effort] = @opts[:reasoning_effort] if @opts[:reasoning_effort].present?
    begin
      response = openai_client.chat(
        parameters: opts,
      )
    rescue => e
      # WARN, not DEBUG: production runs at :info, and a swallowed API error
      # here is indistinguishable from "the model had nothing to say" at every
      # call site. That is how a rejected `temperature` looked like an empty
      # draft for a day. The message is OpenAI's own — no user data in it.
      Rails.logger.warn "**** ERROR - create_chat **** \n#{e.class}: #{e.message}\n"
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
    @model ||= @opts[:model].presence || GTP_MODEL
    Rails.logger.error "**** ERROR **** \nNo messages provided.\n" unless @messages
    opts = {
      model: @model, # Required.
      messages: @messages, # Required.
    }
    opts[:response_format] = @opts[:response_format] if @opts[:response_format].present?
    opts[:temperature] = @opts[:temperature].to_f if @opts[:temperature].present?
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
