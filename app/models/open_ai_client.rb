require "openai"

class OpenAiClient
  DEFAULT_MODEL = "text-davinci-001"
  TURBO_MODEL = "gpt-3.5-turbo"
  GPT_4_STABLE_MODEL = "gpt-4"
  GPT_4_MODEL = "gpt-4-1106-preview"

  def initialize(opts)
    @messages = opts["messages"] || opts[:messages] || []
    @prompt = opts["prompt"] || opts[:prompt] || "backup"
  end

  def self.openai_client
    @openai_client ||= OpenAI::Client.new(access_token: ENV.fetch("OPENAI_ACCESS_TOKEN"))
  end

  def openai_client
    @openai_client ||= OpenAI::Client.new(access_token: ENV.fetch("OPENAI_ACCESS_TOKEN"))
  end

  def create_image
    response = openai_client.images.generate(parameters: { prompt: @prompt, model: "dall-e-3", style: "vivid" })
    if response
      img_url = response.dig("data", 0, "url")
      revised_prompt = response.dig("data", 0, "revised_prompt")
      puts "*** ERROR *** Invaild Image Response: #{response}" unless img_url
      if response.dig("error", "type") == "invalid_request_error"
        puts "**** ERROR **** \n#{response.dig("error", "message")}\n"
        throw "Invaild OpenAI Image Response"
      end
    else
      puts "**** Client ERROR **** \nDid not receive valid response.\n#{response}"
    end
    { img_url: img_url, revised_prompt: revised_prompt }
  end

  def create_audio_from_text(text, voice = "alloy")
    voice = voice || "alloy"
    puts "FROM OpenAiClient: text: #{text} -- voice: #{voice}"
    begin
      response = openai_client.audio.speech(parameters: {
                                              input: text,
                                              model: "tts-1",
                                              voice: voice,
                                            })
    rescue => e
      puts "**** ERROR **** \n#{e.message}\n#{e.inspect}"
    end
    # audio_file = response.stream_to_file("output.mp3")
    # puts "*** Audio File *** #{audio_file}"
    puts "*** ERROR *** Invaild Audio Response: #{response}" unless response
    response
  end

  def self.describe_image(img_url)
    response = openai_client.chat(parameters: { model: "gpt-4-vision-preview", messages: [{ role: "user", content: [{ type: "text", text: "What’s in this image?" }, { type: "image_url", image_url: { url: img_url } }] }] })
    puts "*** ERROR *** Invaild Image Description Response: #{response}" unless response
    # save_response_locally(response)
    response
  end

  def clarify_image_description(image_description)
    puts "Missing image description.\n" && return unless image_description
    @model = GPT_4_MODEL
    @messages = [{ role: "user", content: [{ type: "text", text: "Please parse the following text from a kid's menu and form a clear list of the food and beverage options ONLY.
    Create a short image description for each item based on the name and description.
    The NAME of the food or beverage is the most important part. Ensure that the name is accurate.
    The description is optional. If no description is provided, then try to create a description based on the name.
    Respond as json. 
    Here is an EXAMPLE RESPONSE: #{expected_json_schema}\n
    This is the text to parse: #{strip_image_description(image_description)}\n\n" }] }]
    response = create_chat
    puts "*** ERROR *** Invaild Image Description Response: #{response}" unless response
    response
  end

  def categorize_word(word)
    @model = GPT_4_MODEL
    @messages = [{ role: "user",
                  content: [{type: "text", 
                  text: "Categorize the word '#{word}' into one of the following parts of speech: noun, verb, adjective, adverb, pronoun, preposition, conjunction, or interjection. If the word can be used as multiple parts of speech, choose the most common one. If the word is not a part of speech, respond with 'other'."}] }]
    response = create_chat
    puts "*** ERROR *** Invaild Categorize Word Response: #{response}" unless response
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
    Respond as a JSON object with the following format: {\"next_words\": [\"word1\", \"word2\", \"word3\", ...]}\n or 'NO NEXT WORDS'
    Make your best attempt to provide a list of 24 words or short phrases (2 words max) that are foundational for basic communication in an AAC device. Respond with 'NO NEXT WORDS' if there are no common follow-up words for '#{label}' that would be used in conversation & an AAC device."
  end

  # def next_words_prompt(label)
  #   "For the word '#{label}', decide if it generally leads to a set of specific next words in daily conversations useful for an AAC device. If yes, provide a JSON list of 24 foundational words or short phrases essential for AAC users to express intents, needs, and responses across various situations. Use the format: {\"next_words\": [\"word1\", \"word2\", ...]}. If '#{label}' does not naturally lead to next words, respond with 'NO NEXT WORDS'. Avoid contractions and context-specific words. Two-word phrases are allowed but should be limited. The goal is to populate an AAC device with versatile vocabulary."
  # end

  def get_next_words(label)
    @model = GPT_4_MODEL
    @messages = [{ role: "user",
                  content: [{
      type: "text",
      text: next_words_prompt(label),
    }] }]
    response = create_chat
    puts "*** ERROR *** Invaild Next Words Response: #{response}" unless response
    response
  end

  def strip_image_description(image_description)
    puts "Missing image description.\n" && return unless image_description
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
    puts "*** ERROR *** Invaild Image Description Response: #{response}" unless response
    File.open("response.json", "w") { |f| f.write(response) }
  end

  def create_image_variation(img_url, num_of_images = 1)
    response = openai_client.images.variations(parameters: { image: img_url, n: num_of_images })
    img_variation_url = response.dig("data", 0, "url")
    puts "*** ERROR *** Invaild Image Variation Response: #{response}" unless img_variation_url
    img_variation_url
  end

  def create_chat
    puts "**** ERROR **** \nNo messages provided.\n" unless @messages
    opts = {
      model: GPT_4_STABLE_MODEL, # Required.
      messages: @messages, # Required.
      temperature: 0.7,
    }
    begin
      response = openai_client.chat(
        parameters: opts,
      )
    rescue => e
      puts "**** ERROR **** \n#{e.message}\n"
    end
    if response
      @role = response.dig("choices", 0, "message", "role")
      @content = response.dig("choices", 0, "message", "content")
    else
      puts "**** ERROR **** \nDid not receive valid response.\n"
    end
    { role: @role, content: @content }
  end

  def self.ai_models
    @models = openai_client.models.list
  end
end
