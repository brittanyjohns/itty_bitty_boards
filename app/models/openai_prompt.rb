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
    return if Rails.env.test?
    opts = open_ai_opts.merge({ messages: messages })
    response = OpenAiClient.new(opts).create_chat
    if response
      update!(sent_at: Time.now)
    end
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
    # {
    #   "scenario": "First day of school",
    #   "description": "arrival at the preschool, meeting the teacher and other kids, participating in introductory activities, understanding simple instructions, asking for help, expressing basic needs like hunger, thirst or need for restroom and expressing emotions like happiness, sadness, fear or excitement"
    # }
    "{\"scenario\": \"First day of school\", \"description\": \"arrival at the preschool, meeting the teacher and other kids, participating in introductory activities, understanding simple instructions, asking for help, expressing basic needs like hunger, thirst or need for restroom and expressing emotions like happiness, sadness, fear or excitement\"}"
  end

  def describe_scenario_prompt
    "Please describe the scenario of #{prompt_text} for a person at the age of #{age_range}. Please keep it simple but also very detailed. This will be used to create AAC material for people with speech difficulties. Please respond in JSON with the keys 'scenario' and 'description'.\n\nExample: #{example_scenario_description_response}"
  end

  def resource_type
    "OpenaiPrompt"
  end

  def set_scenario_description
    return if Rails.env.test?
    response = OpenAiClient.new({ messages: [
      { role: "system", content: speech_expert },
      { role: "user", content: describe_scenario_prompt },
    ] }).create_chat

    # create_chat swallows an API error into { role: nil, content: nil }, so a
    # blank content here means "call failed" just as often as "model said
    # nothing". Either way there is no description to set — this used to run
    # nil.gsub and then JSON.parse(nil) and take the whole request down.
    content = response && response[:content]
    if content.blank?
      Rails.logger.error "*** ERROR - set_scenario_description *** Did not receive a usable response."
      return self
    end

    cleaned = content.gsub("```json", "").gsub("```", "").strip
    parsed = valid_json?(cleaned) ? JSON.parse(cleaned) : transform_into_json(cleaned, fallback_key: "description")
    parsed = {} unless parsed.is_a?(Hash)

    self.description = parsed["description"]
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

  # The default used when no PromptTemplate row is configured, or the row has
  # no prompt_text. It was duplicated verbatim in both branches below.
  def default_word_list_prompt
    "Please generate a list of exactly #{number_of_images} unique words or short phrases " \
      "(2 words max - prefer SINGLE WORDS) that are relevant to the scenario #{name}. " \
      "Ensure that the list includes a mix of nouns, verbs, adjectives, and adverbs relevant " \
      "to the activities and items involved in #{name} using the following description for " \
      "additional context. Please make the words appropriate for a person at the age given. " \
      "You can use common/core words if not able to meet number requirement of " \
      "#{number_of_images} words/phrases. Please respond in JSON with the array key 'words_phrases'."
  end

  def word_list_prompt
    prompt_template = PromptTemplate.find_by(method_name: "word_list_prompt")
    if prompt_template.nil?
      Rails.logger.warn "[OpenaiPrompt] PromptTemplate not found for 'word_list_prompt'"
      return default_word_list_prompt
    end

    text = prompt_template.prompt_text
    if text.blank?
      Rails.logger.warn "[OpenaiPrompt] PromptTemplate 'word_list_prompt' has no prompt_text"
      return default_word_list_prompt
    end

    # gsub, not gsub! — the bang form returns nil when a placeholder is absent,
    # so a template row missing {QUANTITY} used to blow up the next line with
    # NoMethodError on nil. PromptTemplate rows are admin-editable, so a
    # template without every placeholder is an ordinary thing to have.
    prompt_text = text
      .gsub("{QUANTITY}", number_of_images.to_s)
      .gsub("{SCENARIO}", scenario.to_s)
      .gsub("{AGE_RANGE}", age_range.to_s)
      .gsub("{NAME}", (name || "the scenario").to_s)

    self.prompt_template_id = prompt_template.id
    save!

    prompt_text
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
      Rails.logger.warn "[OpenaiPrompt] invalid JSON in word-list response"
      json_word_list = transform_into_json(response, fallback_key: "words_phrases")
    end
    # json_word_list = JSON.parse(response)
    images = []
    new_images = []
    tokens_used = 0
    begin
      json_word_list["words_phrases"].each do |word|
        item_name = prompt_image_name(word)
        image = Image.by_label(item_name).find_by(user_id: self.user_id)
        image = Image.by_label(item_name).find_by(private: false) unless image
        image = Image.by_label(item_name).find_by(private: nil) unless image
        new_image = Image.create(label: item_name, image_type: self.class.name) unless image
        image = new_image if new_image
        # A subject description only — Images::PromptBuilder supplies the style
        # spec and constraints at generation time.
        image.image_prompt = item_name
        image.revised_prompt = "'#{item_name}' in the context of #{name}, shown clearly and simply for a person aged #{age_range}"
        image.private = false
        image.image_type = self.class.name
        image.display_description = image.image_prompt
        image.save!
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
      Rails.logger.error "[OpenaiPrompt] create_images_from_response: #{e.class}: #{e.message}"
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
    # The non-alphanumeric strip that used to sit here discarded its own return
    # value, so it has never run. Deliberately not "fixed" into place: it would
    # also eat digits and apostrophes ("don't" -> "dont"), changing which Image
    # every label resolves to. Image#set_label owns label normalisation.
    item_name.to_s.downcase.strip
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
