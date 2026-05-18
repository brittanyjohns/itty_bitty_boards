# == Schema Information
#
# Table name: openai_prompts
#
#  id                 :bigint           not null, primary key
#  user_id            :bigint           not null
#  prompt_text        :text
#  revised_prompt     :text
#  send_now           :boolean          default(FALSE)
#  deleted_at         :datetime
#  sent_at            :datetime
#  private            :boolean          default(FALSE)
#  age_range          :string
#  token_limit        :integer
#  response_type      :string
#  description        :text
#  number_of_images   :integer          default(0)
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  prompt_template_id :integer
#  name               :string
#
class OpenaiPrompt < ApplicationRecord
  belongs_to :user
  has_many :boards, as: :parent, dependent: :destroy
  include UtilHelper

  def send_prompt_to_openai
    opts = open_ai_opts.merge({ messages: messages })
    response = OpenAiClient.new(opts).create_chat
    update!(sent_at: Time.now) if response
    response
  end

  def name
    board = boards.last
    board&.name || prompt_text
  end

  def open_ai_opts
    { prompt: prompt_to_send }
  end

  def prompt_to_send
    prompt_text
  end

  def example_scenario_description_response
    {
      "scenario" => "First day of school",
      "description" => "arrival at the preschool, meeting the teacher and other kids, participating in introductory activities, understanding simple instructions, asking for help, expressing basic needs like hunger, thirst or need for restroom and expressing emotions like happiness, sadness, fear or excitement",
    }.to_json
  end

  def describe_scenario_prompt
    age_clause = age_range.present? ? " for a person aged #{age_range}" : ""
    <<~PROMPT.strip
      Describe the scenario "#{prompt_text}"#{age_clause} as it would be experienced
      by an AAC user — the people and things they encounter, the actions involved,
      and the feelings or needs they might want to express. Keep it concrete and
      grounded; this will be used to generate vocabulary for an AAC board.

      Respond as a JSON object with exactly two string keys: "scenario" and "description".

      Example:
      #{example_scenario_description_response}
    PROMPT
  end

  def resource_type
    "OpenaiPrompt"
  end

  def set_scenario_description
    response = OpenAiClient.new({ messages: [
      { role: "system", content: speech_expert },
      { role: "user", content: describe_scenario_prompt },
    ] }).create_chat

    content = response&.dig(:content)
    if content.blank?
      Rails.logger.error "*** ERROR - set_scenario_description *** empty response: #{response.inspect}"
      return self
    end

    description = AiResponseParser.fetch(content, key: "description")
    if description.blank?
      Rails.logger.error "*** ERROR - set_scenario_description *** missing 'description' key in: #{content.inspect}"
      return self
    end

    self.description = description
    self
  end

  def scenario
    if description.blank?
      prompt_text
    else
      "#{prompt_text} which would involve #{description}"
    end
  end

  def speech_expert
    "You are a speech expert and have done extensive research of people with special needs & how they communicate in various scenarios."
  end

  def word_list_prompt
    prompt_template = PromptTemplate.find_by(method_name: "word_list_prompt")
    text = prompt_template&.prompt_text

    if text.blank?
      Rails.logger.warn "PromptTemplate 'word_list_prompt' missing or empty; using fallback"
      return default_word_list_prompt
    end

    name_to_send = name.presence || "the scenario"
    rendered = text
      .gsub("{QUANTITY}", number_of_images.to_s)
      .gsub("{SCENARIO}", scenario.to_s)
      .gsub("{AGE_RANGE}", age_range.to_s)
      .gsub("{NAME}", name_to_send)

    self.prompt_template_id = prompt_template.id
    save!

    rendered
  end

  def default_word_list_prompt
    name_to_send = name.presence || "the scenario"
    age_clause = age_range.present? ? " appropriate for a person aged #{age_range}" : ""
    <<~PROMPT.strip
      Generate EXACTLY #{number_of_images} unique words or short (max 2 words) phrases
      that someone using an AAC device would most likely need during "#{name_to_send}".

      Rules:
      - Prefer single words. Use a 2-word phrase only when it is the natural AAC form.
      - Include a mix of nouns, verbs, adjectives, and adverbs related to the scenario.
      - Include core communication words (I, want, more, stop, help) when relevant.
      - Lowercase only, except proper nouns. No punctuation.
      - No duplicates or near-duplicates.
      - Keep the words#{age_clause}.

      Respond as a JSON object with a single array key "words_phrases".
    PROMPT
  end

  def messages
    [
      {
        "role": "system",
        "content": "#{speech_expert} #{word_list_prompt}.",
      },
      {
        "role": "user",
        "content": "{\"scenario\": \"#{scenario}\", \"age\": \"#{age_range}\"}",
      },
    ]
  end

  def self.age_range_list
    ["1-3", "4-6", "7-9", "10-12", "13-15", "16-18", "19-21", "22-25", "26-30", "31-35", "36-40", "41-45", "46-50", "51-55", "56-60", "61-65", "66-70", "71-75", "76-80", "81-85", "86-90", "91-95", "96-100"]
  end

  def create_board_from_response(response, token_limit)
    board = self.boards.last || self.boards.new(user: self.user, name: name)
    board.user = self.user
    board.name = prompt_text if board.name.blank?
    board.token_limit = token_limit
    board.description = response
    board.save!
    create_images_from_response(board, response)
    board.reset_layouts
    board.set_display_image
    board.update!(status: "completed")
    board
  end

  def create_images_from_response(board, response)
    json_word_list = nil
    if valid_json?(response)
      json_word_list = JSON.parse(response)
    else
      puts "INVALID JSON: #{response}"
      json_word_list = transform_into_json(response)
    end
    # json_word_list = JSON.parse(response)
    images = []
    new_images = []
    tokens_used = 0
    begin
      json_word_list["words_phrases"].each do |word|
        item_name = prompt_image_name(word)
        image = Image.find_by(label: item_name, user_id: self.user_id)
        image = Image.find_by(label: item_name, private: false) unless image
        image = Image.find_by(label: item_name, private: nil) unless image
        new_image = Image.create(label: item_name, image_type: self.class.name) unless image
        image = new_image if new_image
        image.image_prompt = item_name
        image.revised_prompt = "Create a high-resolution image of '#{item_name}' in the context of #{name} for a person at the age of #{age_range}. Please make the images are clear, simple & appropriate for a person at the age given."
        image.private = false
        image.image_type = self.class.name
        image.display_description = image.image_prompt
        image.save!
        image.revised_prompt += Image::PROMPT_ADDITION
        board.add_image(image.id)
        images << image
        new_images << new_image if new_image
      end
      total_cost = board.cost || 0
      minutes_to_wait = 0
      new_images.each_slice(5) do |image_slice|
        image_slice.each do |image|
          next unless should_generate_image(image, self.user, tokens_used, total_cost)
          image.start_generate_image_job(minutes_to_wait, self.user_id, image.revised_prompt)
          tokens_used += 1
          total_cost += 1
        end
        minutes_to_wait += 1
      end
    rescue => e
      puts "ERROR - create_images_from_response: #{e.message} \n#{e.backtrace}"
      board.update(status: "error") if board
    end
    self.user.remove_tokens(tokens_used)
    board.add_to_cost(tokens_used) if board
  end

  # def should_generate_image(image, user, tokens_used, total_cost = 0)
  #   return false if image.doc_exists_for_user?(user)
  #   return false if user.tokens <= tokens_used
  #   return false if token_limit <= total_cost
  #   true
  # end

  def prompt_image_name(item_name)
    item_name.downcase!
    # Strip out any non-alphanumeric characters
    item_name.gsub(/[^a-z ]/i, "")
    item_name
  end

  def api_view_with_images(user)
    last_board = boards.last
    {
      id: id,
      prompt_text: prompt_text,
      revised_prompt: revised_prompt,
      send_now: send_now,
      deleted_at: deleted_at,
      sent_at: sent_at,
      private: private,
      age_range: age_range,
      response_type: response_type,
      number_of_images: number_of_images,
      user: user,
      board_id: last_board&.id,
      status: last_board&.status,
      name: last_board&.name,
    }
  end
end
