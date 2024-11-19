require "openai"

class OpenAiClient
  GPT_4_MODEL = "gpt-4o"
  GPT_3_MODEL = "gpt-3.5-turbo-0125"
  IMAGE_MODEL = "dall-e-2"
  TTS_MODEL = "tts-1"
  PREVIEW_MODEL = "o1-preview"

  def initialize(opts)
    @messages = opts["messages"] || opts[:messages] || []
    @prompt = opts["prompt"] || opts[:prompt] || "backup"
  end

  def self.openai_client
    @openai_client ||= OpenAI::Client.new(access_token: ENV.fetch("OPENAI_ACCESS_TOKEN"), log_errors: Rails.env.development?)
  end

  def openai_client
    @openai_client ||= OpenAI::Client.new(access_token: ENV.fetch("OPENAI_ACCESS_TOKEN"), log_errors: Rails.env.development?)
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

  def create_image
    Rails.logger.debug "Prompt: #{@prompt}"
    new_prompt = create_image_prompt
    Rails.logger.debug "New Prompt: #{new_prompt}"

    response = openai_client.images.generate(parameters: { prompt: new_prompt, model: IMAGE_MODEL })
    if response
      img_url = response.dig("data", 0, "url")
      revised_prompt = response.dig("data", 0, "revised_prompt")
      Rails.logger.debug "*** ERROR *** Invaild Image Response: #{response}" unless img_url
      if response.dig("error", "type") == "invalid_request_error"
        Rails.logger.debug "**** ERROR **** \n#{response.dig("error", "message")}\n"
        throw "Invaild OpenAI Image Response"
      end
    else
      Rails.logger.debug "**** Client ERROR **** \nDid not receive valid response.\n#{response}"
    end
    { img_url: img_url, revised_prompt: revised_prompt, edited_prompt: new_prompt }
  end

  def create_audio_from_text(text, voice = "alloy")
    return if Rails.env.test?
    voice = voice || "alloy"
    Rails.logger.debug "FROM OpenAiClient: text: #{text} -- voice: #{voice}"
    begin
      response = openai_client.audio.speech(parameters: {
                                              input: text,
                                              model: TTS_MODEL,
                                              voice: voice,
                                            })
    rescue => e
      Rails.logger.debug "**** ERROR **** \n#{e.message}\n#{e.inspect}"
    end
    # audio_file = response.stream_to_file("output.mp3")
    # Rails.logger.debug "*** Audio File *** #{audio_file}"
    Rails.logger.debug "*** ERROR *** Invaild Audio Response: #{response}" unless response
    response
  end

  def self.describe_image(img_url)
    response = openai_client.chat(parameters: { model: "gpt-4-vision-preview", messages: [{ role: "user", content: [{ type: "text", text: "What's in this image?" }, { type: "image_url", image_url: { url: img_url } }] }] })
    Rails.logger.debug "*** ERROR *** Invaild Image Description Response: #{response}" unless response
    # save_response_locally(response)
    response
  end

  def create_image_prompt
    new_prompt = specific_image_prompt(@prompt)
    response = openai_client.chat(parameters: { model: GPT_3_MODEL, messages: [{ role: "user", content: [{ type: "text", text: new_prompt }] }] })
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

  def generate_formatted_board(name, num_of_columns, words = [], max_num_of_rows = 4)
    @model = PREVIEW_MODEL
    Rails.logger.debug "User - model: #{@model} -- name: #{name} -- num_of_columns: #{num_of_columns} -- words: #{words} -- max_num_of_rows: #{max_num_of_rows}"
    @messages = [{ role: "user",
                  content: [{ type: "text",
                              text: format_board_prompt(name, num_of_columns, words, max_num_of_rows) }] }]
    response = create_completion
    Rails.logger.debug "*******\nResponse: #{response}\n"
    Rails.logger.debug "*** ERROR *** Invaild Formatted Board Response: #{response}" unless response
    response[:content]
  end

  def clarify_image_description(image_description)
    Rails.logger.debug "Missing image description.\n" && return unless image_description
    @model = GPT_4_MODEL
    @messages = [{ role: "user", content: [{ type: "text",
                                           text: "Please parse the following text from a restaurant menu to 
                                                form a clear list of the food and beverage options ONLY.
                                                Create a short image description for each item based on the name and description.
                                                The NAME of the food or beverage is the most important part. Ensure that the name is accurate.
                                                The description is optional. If no description is provided, then try to create a description based on the name.
                                                Respond as json. 
                                                Here is an EXAMPLE RESPONSE: #{expected_json_schema}\n
                                                This is the text to parse: #{strip_image_description(image_description)}\n\n" }] }]
    response = create_chat
    Rails.logger.debug "*** ERROR *** Invaild Image Description Response: #{response}" unless response
    # response
    [response, @messages[0][:content][0][:text]]
  end

  def categorize_word(word)
    @model = GPT_3_MODEL
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

  def format_board_prompt(name, num_of_columns, word_array = [], max_num_of_rows = 4)
    puts "max_num_of_rows: #{max_num_of_rows}"
    Rails.logger.debug "\nName: #{name} -- Num of Columns: #{num_of_columns} -- Max Num of Rows: #{max_num_of_rows}\n"
    words = word_array.join(", ") unless word_array.blank?
    word_count = word_array.size
    text = <<-PROMPT
      Create an AAC communication board formatted as a grid layout.

      Organize the words based on these guidelines:
      1. Core words should be placed first and grouped together, prioritizing high-frequency words - Stating with the coordinate [0,0].
      2. Group words by parts of speech (e.g., pronouns, verbs, adjectives).
      3. Consider how speech-language pathologists arrange words for ease of use in communication, ensuring frequently used words are near the top left.
      4. Use a grid layout with a MAXIMUM of #{num_of_columns} columns and MAX rows: #{max_num_of_rows}.
      5. Each entry should include the word, its grid position as [x, y], its part of speech, and its frequency of use.

      Please create a grid layout that include the words: '#{words}', grouped and positioned based on their typical use in AAC communication.
      It is VERY important that the Y-COOORDINATE should not exceed #{max_num_of_rows} and the X-COORDINATE should not exceed #{num_of_columns}.
      Please also provide a professional explanation (for a speech-language pathologist) and a personable explanation (for a caregiver or user - but still professional) of the layout.
      
       Please respond as a valid JSON object with the following structure:

      {
        "grid": [
          {"word": "I", "position": [0,0], "part_of_speech": "pronoun", "frequency": "high"},
          {"word": "want", "position": [0,1], "part_of_speech": "verb", "frequency": "high"},
          {"word": "more", "position": [0,2], "part_of_speech": "adverb", "frequency": "high"},
          ...
          {"word": "elevator", "position": [5,10], "part_of_speech": "noun", "frequency": "low"},
        ],
        "professional_explanation": "This layout is designed to help users quickly find and use the most common words in AAC communication. The words are grouped by parts of speech and arranged in a grid to make it easy to locate and select the right word.",
        "personable_explanation": "This board is set up to help you find the words you need to communicate quickly and easily. The words are grouped by type and placed in a grid so you can find them easily."
      }
    PROMPT
  end

  def get_next_words(label)
    @model = GPT_4_MODEL
    @messages = [{ role: "user",
                  content: [{
      type: "text",
      text: next_words_prompt(label),
    }] }]
    response = create_chat
    Rails.logger.debug "*** ERROR *** Invaild Next Words Response: #{response}" unless response
    response
  end

  def get_additional_words(board, name, number_of_words = 24, exclude_words = [], use_preview_model = false)
    exclude_words_prompt = exclude_words.blank? ? "and no words to exclude." : "excluding the words '#{exclude_words.join("', '")}'."
    puts "Exclude Words: #{exclude_words}"
    puts "use_preview_model: #{use_preview_model}"

    is_dynamic_board = board&.parent_type == "Image"
    text = ""
    if !is_dynamic_board
      first_sentence = name.include?("Default") ? "I have the initial communication board displayed to the user." : "I have an existing AAC board titled, '#{name}'"
      word_instructions = "#{first_sentence} with the current words: [#{exclude_words_prompt}]. Please provide EXACTLY #{number_of_words} additional words that are foundational for basic communication in an AAC device."

      static_instructions = "These words should be broadly applicable, supporting users in expressing a variety of intents, needs, and responses across different situations. They should be similar in nature to the words already on the board, but not duplicates."
      text = "#{word_instructions} #{static_instructions}"
    else
      text = "I have an AAC board & the last word/phrase selected was '#{name}'. Please provide #{number_of_words} words/phrases that are most likely to be used next in conversation after the word/phrase '#{name}'."
    end
    format_instructions = "Do not repeat any words that are already on the board & only provide #{number_of_words} words. DO NOT INCLUDE [#{exclude_words_prompt}]. 
    If the board is 'go to', words like 'home', 'school', 'store', 'park', etc. would be appropriate. 
    If the board is 'feeling', words like 'happy', 'sad', 'angry', 'tired', etc. would be appropriate.
     If the board is 'drink', words like 'water', 'milk', 'juice', 'thirsty', etc. would be appropriate.
     If the board is 'will', words like 'you', 'I', 'we', 'they', etc. would be appropriate.
     If the board is 'food', words like 'apple', 'banana', 'cookie', 'hungry', etc. would be appropriate.
    Respond with a JSON object in the following format: {\"additional_words\": [\"word1\", \"word2\", \"word3\", ...]}"
    text = "#{text} #{format_instructions}"
    @messages = [{ role: "user",
                  content: [{
      type: "text",
      text: text,
    }] }]
    if use_preview_model
      @model = PREVIEW_MODEL
      response = create_completion
    else
      @model = GPT_4_MODEL
      response = create_chat
    end
    Rails.logger.debug "*** ERROR *** Invaild Additional Words Response: #{response}" unless response
    response
  end

  def get_word_suggestions(name, number_of_words = 24)
    @model = GPT_4_MODEL
    text = "I have an existing AAC board titled, '#{name}'. Inferring the context from the name, please provide #{number_of_words} words that are foundational for basic communication in an AAC device.
    These words should relate to the context of the board and be broadly applicable, supporting users in expressing a variety of intents, needs, and responses across different situations. 
    Examples: If the board is named 'drink', words like 'water', 'milk', 'juice', 'thirsty', etc. would be appropriate. 
    If the board is 'go to', words like 'home', 'school', 'store', 'park', etc. would be appropriate. 
    If the board is 'feelings', words like 'happy', 'sad', 'angry', 'tired', etc. would be appropriate.
    If the board is 'family', words like 'mom', 'dad', 'sister', 'brother', etc. would be appropriate.
    Respond with a JSON object in the following format: {\"words\": [\"word1\", \"word2\", \"word3\", ...]}"

    @messages = [{ role: "user",
                  content: [{
      type: "text",
      text: text,
    }] }]
    response = create_chat
    Rails.logger.debug "*** ERROR *** Invaild Word Suggestion Response: #{response}" unless response
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

  def create_image_variation(img_url, num_of_images = 1)
    response = openai_client.images.variations(parameters: { image: img_url, n: num_of_images })
    img_variation_url = response.dig("data", 0, "url")
    Rails.logger.debug "*** ERROR *** Invaild Image Variation Response: #{response}" unless img_variation_url
    img_variation_url
  end

  def create_chat
    @model ||= GPT_3_MODEL
    Rails.logger.debug "**** ERROR **** \nNo messages provided.\n" unless @messages
    opts = {
      model: @model, # Required.
      messages: @messages, # Required.
      temperature: 0.7,
      response_format: { type: "json_object" },
    }
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
    @model ||= PREVIEW_MODEL
    Rails.logger.error "**** ERROR **** \nNo messages provided.\n" unless @messages
    Rails.logger.debug "Sending to model: #{@model}"
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

  def self.ai_models
    @models = openai_client.models.list
  end
end
