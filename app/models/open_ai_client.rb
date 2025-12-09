require "openai"

class OpenAiClient
  # GTP_MODEL = "gpt-4o"
  GTP_MODEL = ENV.fetch("OPENAI_GTP_MODEL", "gpt-4o")
  QUICK_GTP_MODEL = ENV.fetch("OPENAI_QUICK_GTP_MODEL", "gpt-4o-mini")
  IMAGE_MODEL = ENV.fetch("OPENAI_IMAGE_MODEL", "dall-e-3")
  IMAGE_MOBEL_STYLE = ENV.fetch("OPENAI_IMAGE_MODEL_STYLE", "natural")
  # IMAGE_MODEL = "gpt-image-1"
  # TTS_MODEL = "tts-1"
  TTS_MODEL = ENV.fetch("OPENAI_TTS_MODEL", "gpt-4o-mini-tts")
  PREVIEW_MODEL = "o1-preview"

  def initialize(opts)
    @messages = opts["messages"] || opts[:messages] || []
    @prompt = opts["prompt"] || opts[:prompt] || "backup"
  end

  def self.openai_client
    @openai_client ||= OpenAI::Client.new(access_token: ENV.fetch("OPENAI_ACCESS_TOKEN"), log_errors: true)
  end

  def openai_client
    @openai_client ||= OpenAI::Client.new(access_token: ENV.fetch("OPENAI_ACCESS_TOKEN"), log_errors: true)
  end

  # def specific_image_prompt(img_prompt)
  #   "Can you create a text prompt for me that I can use with DALL-E to generate an image of a cartoon character expressing a certain emotion or doing a specific action.
  #   Or if the word is an object, write a prompt to generate an image of that object in a clear and simple way.
  #   Use as much detail as possible in order to generate an image that a child could easily recognize that the image represents this word/phrase: '#{img_prompt}'.
  #   Respond with the prompt only, not the image or any other text.  It should be very clear that the word/phrase is '#{img_prompt}'."
  # end

  def specific_image_prompt(img_prompt)
    "Can you create a text prompt for me that I can use with DALL-E to generate an image that is clear and simple, similar to AAC and other accessibility signs?
    The image should represent the word/phrase '#{img_prompt}' in a way that a child could easily recognize. Avoid cartoonish styles.
    Use as much detail as possible to ensure clarity and simplicity. Respond with the prompt only, not the image or any other text. Respond in JSON format."
  end

  def static_image_prompt
    "Create a simple, clear, and colorful clipart-style image representing the concept of '{userInput}'. 
    The image should be easily recognizable at a glance and suitable for use on AAC communication boards. 
    Use a minimalistic design with bold, high-contrast colors. Avoid backgrounds, unnecessary details, or text in the image. 
    Ensure the visual meaning is obvious and aligns with how the word is commonly represented in communication aids.".gsub("{userInput}", @prompt)
  end

  def image_style
    "simple, clear, and colorful clipart-style image"
  end

  def get_image_prompt_suggestion
    @model = GTP_MODEL
    base_prompt = <<~PROMPT
      Generate a descriptive and concise prompt to instruct #{IMAGE_MODEL} to create a #{image_style} representing the word/phrase "#{@prompt}".
      If the word is an object, the image should clearly depict that object in a simple and recognizable way.
      If the word is an action or emotion, descriibe a happy person performing that action or expressing that emotion.
      No text or letters should be included in the image.
    PROMPT

    @messages = [{
      role: "user",
      content: [{ type: "text", text: base_prompt }],
    }]

    response = create_chat(false)
    prompt = response.with_indifferent_access.dig("content")

    prompt
  end

  def create_image
    # new_prompt = static_image_prompt
    new_prompt = @prompt

    response = openai_client.images.generate(parameters: { prompt: new_prompt, model: IMAGE_MODEL, style: IMAGE_MOBEL_STYLE })
    if response
      img_url = response.dig("data", 0, "url")
      b64_json = response.dig("data", 0, "b64_json")
      revised_prompt = response.dig("data", 0, "revised_prompt")
      Rails.logger.error "*** ERROR *** Invaild Image Response: #{response}" unless img_url || b64_json
      if response.dig("error", "type") == "invalid_request_error"
        Rails.logger.error "**** ERROR **** \n#{response.dig("error", "message")}\n"
        throw "Invaild OpenAI Image Response"
      end
    else
      Rails.logger.error "**** Client ERROR **** \nDid not receive a response.\n#{response}"
    end
    { img_url: img_url, revised_prompt: revised_prompt, edited_prompt: new_prompt, b64_json: b64_json }
  end

  def create_audio_from_text(text, voice = "alloy", language = "en")
    return if Rails.env.test?
    if voice.blank?
      voice = "alloy"
    end
    begin
      response = openai_client.audio.speech(parameters: {
                                              input: text,
                                              model: TTS_MODEL,
                                              voice: voice,
                                            })
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

  def describe_menu(img_url)
    begin
      response = openai_client.chat(parameters: {
                                      model: GPT_VISION_MODEL,
                                      messages: [{ role: "user",
                                                  content: [{ type: "text",
                                                              text: "This is a restaurant menu. Please describe the menu items in a list like your were reading them to the server. Please respond as json in the following format: #{expected_json_schema}" },
                                                            { type: "image_url", image_url: { url: img_url } }] }],
                                    })
      Rails.logger.debug "*** ERROR *** Invaild Menu Description Response: #{response}" unless response
    rescue => e
      Rails.logger.debug "**** ERROR **** \n#{e.message}\n#{e.inspect}"
    end
    # save_response_locally(response)
    response
  end

  def create_image_prompt
    new_prompt = specific_image_prompt(@prompt)
    response = openai_client.chat(parameters: { model: GTP_MODEL, messages: [{ role: "user", content: [{ type: "text", text: new_prompt }] }] })
    Rails.logger.debug "*** ERROR *** Invaild Image Prompt Response: #{response}" unless response
    Rails.logger.debug "Response: #{response.inspect}" if response
    image_prompt_content = nil
    if response
      image_prompt_content = response.dig("choices", 0, "message", "content")
    else
      Rails.logger.debug "**** ERROR **** \nDid not receive valid response.\n"
    end
    Rails.logger.debug "Image Prompt Content: #{image_prompt_content}"
    @prompt = image_prompt_content
    image_prompt_content
  end

  def generate_formatted_board(name, num_of_columns, words = [], max_num_of_rows = 4, maintain_existing = false)
    @model = GTP_MODEL
    Rails.logger.debug "User - model: #{@model} -- name: #{name} -- num_of_columns: #{num_of_columns} -- words: #{words.count} -- max_num_of_rows: #{max_num_of_rows}"
    @messages = [{ role: "user",
                  content: [{ type: "text",
                              text: format_board_prompt(name, num_of_columns, words, max_num_of_rows, maintain_existing) }] }]
    response = create_completion
    Rails.logger.debug "*******\nResponse: #{response}\n"
    Rails.logger.debug "*** ERROR *** Invaild Formatted Board Response: #{response}" unless response
    response[:content] if response
  end

  def clarify_image_description(image_description, restaurant_name)
    Rails.logger.debug "Missing image description.\n" && return unless image_description
    @model = GTP_MODEL
    @messages = [{ role: "user", content: [{ type: "text",
                                           text: "Please parse the following text from a restaurant menu from the
                                                restaurant '#{restaurant_name}' to
                                                form a clear list of the food and beverage options ONLY.
                                                Create a short image description for each item based on the name and description.
                                                The NAME of the food or beverage is the most important part. Ensure that the name is accurate.
                                                The description is optional. If no description is provided, then try to create a description based on the name.
                                                Respond as json. 
                                                Here is an EXAMPLE RESPONSE: #{expected_json_schema}\n
                                                This is the text to parse: #{strip_image_description(image_description)}\n\n" }] }]
    response = create_chat
    Rails.logger.debug "*** ERROR *** Invaild Image Description Response: #{response}" unless response
    [response, @messages[0][:content][0][:text]]
  end

  def format_menu_description(menu_description)
    @model = GTP_MODEL
    @messages = [{ role: "user", content: [{ type: "text",
                                           text: "Please parse the following description from a restaurant menu to
                                                form a clear list of the food and beverage options ONLY.
                                                Create a short image description for each item based on the name and description.
                                                The NAME of the food or beverage is the most important part. Ensure that the name is accurate.
                                                The description is optional. If no description is provided, then try to create a description based on the name.
                                                Respond as json.
                                                Here is an EXAMPLE RESPONSE: #{expected_json_schema}\n
                                                This is the text to parse: #{strip_image_description(menu_description)}\n" }] }]
    response = create_chat
    Rails.logger.debug "*** ERROR *** Invaild Menu Description Response: #{response}" unless response
    response
  end

  def categorize_word(word)
    @model = QUICK_GTP_MODEL
    @messages = [{ role: "user",
                  content: [{ type: "text",
                              text: "Categorize the word '#{word}' into one of the following parts of speech: #{Image.valid_parts_of_speech} If the word can be used as multiple parts of speech, choose the most common one. If the word is not a part of speech, respond with 'other'. Respond as json. Example: {\"part_of_speech\": \"noun\"}" }] }]
    response = create_chat
    Rails.logger.debug "*** ERROR *** Invaild Categorize Word Response: #{response}" unless response
    response
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

  def get_words_for_scenario(scenario_description, number_of_words = 24, language = "en")
    prompt = <<~PROMPT
      I have a scenario description: "#{scenario_description}".
      
      Please provide #{number_of_words} words that are foundational for basic communication in an AAC device.
      These words should relate to the context of the scenario and be broadly applicable, supporting users in expressing a variety of intents, needs, and responses across different situations.
      Do not repeat any words that are already on the board & only provide #{number_of_words} words.
      Respond with a JSON object in the following format: {\"words\": [\"word1\", \"word2\", \"word3\", ...]}
    PROMPT

    @model = QUICK_GTP_MODEL
    @messages = [{ role: "user",
                   content: [{ type: "text", text: prompt }] }]
    response = create_chat
    Rails.logger.debug "*** ERROR *** Invaild Words for Scenario Response: #{response}" unless response
    Rails.logger.debug "Words for Scenario Response: #{response.inspect}"
    response
  end

  def get_additional_words(board, name, number_of_words = 24, exclude_words = [], use_preview_model = false, language = "en")
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
    language = language || "en"
    if language != "en"
      formatted_language = LONG_LANGUAGE_NAMES[language.to_sym]
      format_instructions += " Respond in #{formatted_language}." if formatted_language
    end
    text = "#{text} #{format_instructions} #{ending}"
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

  def get_word_suggestions(name, number_of_words = 24, words_to_exclude = [])
    if words_to_exclude.is_a?(String)
      words_to_exclude = words_to_exclude.split(",").map(&:strip)
    end
    @model = QUICK_GTP_MODEL
    Rails.logger.debug "User - model: #{@model} -- name: #{name} -- number_of_words: #{number_of_words} -- words_to_exclude: #{words_to_exclude.inspect}"
    text = "I have an AAC board titled, '#{name}'. Inferring the context from the name, please provide #{number_of_words} words. "

    unless words_to_exclude.blank?
      text += " Do not repeat any words that are already on the board & only provide #{number_of_words} words, excluding the words '#{words_to_exclude.join("', '")}'."
    end
    format_instructions = "Respond with a JSON object in the following format: {\"words\": [\"word1\", \"word2\", \"word3\", ...]}"
    text += format_instructions
    examples = <<~EXAMPLES
      Examples: If the board is named 'drink', words like 'water', 'milk', 'juice', 'thirsty', etc. would be appropriate. 
      If the board is 'food', words like 'apple', 'banana', 'cookie', 'eat', etc. would be appropriate.
      If the board is 'Trip to the park', words like 'play', 'my turn', 'swing', 'slide', etc. would be appropriate.
      If the board is 'nature', words like 'tree', 'flower', 'sun', 'rain', etc. would be appropriate.
      If the board is 'go to', words like 'home', 'school', 'store', 'park', etc. would be appropriate. 
      If the board is 'feelings', words like 'happy', 'sad', 'angry', 'tired', etc. would be appropriate.
      If the board is 'family', words like 'mom', 'dad', 'sister', 'brother', etc. would be appropriate.
    EXAMPLES
    text += examples
    @messages = [{ role: "user",
                  content: [{
      type: "text",
      text: text,
    }] }]
    response = create_chat
    puts "*******\nResponse: #{response}\n"
    response
  end

  # def get_board_description(name, word_tree, grid_info)
  #   @model = GTP_MODEL
  #   text = "I have an AAC board titled, '#{name}'. The board is designed to help users communicate using a grid layout with words and phrases. The board includes the following words: #{word_tree}.
  #    The grid sizes are: #{grid_info}.

  #   Please provide a brief description of it, including intended use, target age/experience level & why it's laid out how it is, etc.
  #   Please don't include the words on the board in the description. Keep the description concise and easy to understand.
  #    Respond in HTML format."

  #   @messages = [{ role: "user",
  #                 content: [{
  #     type: "text",
  #     text: text,
  #   }] }]
  #   response = create_chat(false)
  #   Rails.logger.debug "*** ERROR *** Invaild board description Response: #{response}" unless response
  #   response
  # end

  # def get_board_description(name, word_tree, grid_info)
  #   @model = GTP_MODEL
  #   text = <<~TEXT
  #     I have an AAC board titled, "#{name}". This board is designed to help users communicate effectively using a structured grid layout.

  #     **Board Details:**
  #     - Grid sizes: #{grid_info}
  #     - The board includes a variety of core and fringe vocabulary words but do not list them in the description.

  #     **Instructions:**
  #     - Provide a **concise, well-structured HTML response** describing the board's **purpose, target audience (age/experience level), and layout rationale**.
  #     - Use **clear, easy-to-read language**.
  #     - **Do not list the words** on the board.
  #     - Structure the response in **HTML format**, using `<p>` for paragraphs and `<strong>` for key terms.

  #     **Example Output Format:**
  #     ```html
  #     <p><strong>Purpose:</strong> This AAC board supports communication in [specific scenario, e.g., outdoor play, school, daily routines]. It allows users to express needs, actions, and social interactions efficiently.</p>
  #     <p><strong>Target Audience:</strong> Suitable for [age/experience level, e.g., young children, emerging communicators, individuals with limited speech].</p>
  #     <p><strong>Layout:</strong> The grid is designed to balance core words for flexibility and fringe words for specific contexts. The layout promotes quick access to high-frequency terms.</p>
  #     ```
  #   TEXT

  #   @messages = [{ role: "user",
  #                 content: [{
  #     type: "text",
  #     text: text,
  #   }] }]
  #   response = create_chat(false)
  #   Rails.logger.debug "*** ERROR *** Invalid board description Response: #{response}" unless response
  #   response
  # end

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

  def strip_image_description(image_description)
    Rails.logger.debug "Missing image description.\n" && return unless image_description
    stripped_description = image_description.gsub(/[^a-z ]/i, "")
    stripped_description
  end

  def expected_json_schema
    {
      "menu_items": [
        {
          "name": "Chicken Tenders",
          "description": "Served with french fries and honey mustard sauce.",
          "image_description": "Chicken tenders with french fries and honey mustard sauce.",
        },
        {
          "name": "Cheeseburger",
          "description": "Served with french fries.",
          "image_description": "Cheeseburger with french fries.",
        },
        {
          "name": "Milk",
        },
        {
          "name": "Apple Juice",
          "image_description": "Apple juice in a cup.",
        },
        {
          "name": "Ice Cream",
          "description": "Vanilla ice cream with chocolate sauce.",
        },
      ],
    }
  end

  def save_response_locally(response)
    Rails.logger.debug "*** ERROR *** Invaild Image Description Response: #{response}" unless response
    File.open("response.json", "w") { |f| f.write(response) }
  end

  def create_image_variation(img, num_of_images = 1)
    response = openai_client.images.variations(parameters: { image: img, n: 1 })
    img_variation_url = response.dig("data", 0, "url")
    Rails.logger.debug "*** ERROR *** Invaild Image Variation Response: #{response}" unless img_variation_url
    img_variation_url
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
    # temperature: 0.7,
    # response_format: { type: "json_object" },
    }
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
end
