# == Schema Information
#
# Table name: scenarios
#
#  id                  :bigint           not null, primary key
#  questions           :json
#  answers             :json
#  name                :string
#  initial_description :text
#  age_range           :string
#  user_id             :bigint           not null
#  status              :string           default("pending")
#  word_list           :string           default([]), is an Array
#  token_limit         :integer          default(10)
#  board_id            :integer
#  send_now            :boolean          default(FALSE)
#  number_of_images    :integer          default(0)
#  tokens_used         :integer          default(0)
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
class Scenario < ApplicationRecord
  attr_accessor :finalize
  belongs_to :user
  belongs_to :board, optional: true
  include UtilHelper

  def api_view_with_images(viewing_user)
    self.answers ||= {}
    self.questions ||= {}
    questions_array = []
    questions.each do |key, value|
      questions_array << { key: key, question: value, answer: answers[key] }
    end
    answers_array = []
    answers.each do |key, value|
      answers_array << { key: key, answer: value }
    end

    view = self.as_json
    view["questions"] = questions_array
    view["answers"] = answers_array
    view["can_edit"] = viewing_user == self.user || viewing_user.admin?
    view["user"] = self.user.as_json
    view["board"] = self.board.api_view_with_images(viewing_user) if self.board
    view
  end

  def api_view
    {
      id: id,
      name: name,
      initial_description: initial_description,
      age_range: age_range,
      user_id: user_id,
      status: status,
      created_at: created_at,
      updated_at: updated_at,
      word_list: word_list,
    }
  end

  def transform_word_list_response(raw_word_list)
    # Transform the word list response to remove any special characters
    # and ensure that each word is a string
    updated_list = raw_word_list.map! do |word|
      word.gsub(/[^a-z ]/i, "").split(" ").map(&:strip).reject(&:empty?)
    end
    updated_list.flatten
  end

  def create_board_with_images
    board = Board.find_by(id: self.board_id)
    board = Board.create!(user: self.user, name: self.name, token_limit: self.token_limit, description: self.initial_description) unless board

    board_with_images = generate_images_from_word_list(board)
    board_with_images.reset_layouts
    board_with_images.set_display_image
    board_with_images.update!(status: "completed")
    board_with_images
  end

  def generate_images_from_word_list(board)
    images = []
    new_images = []
    tokens_used = 0
    begin
      word_list.each do |word|
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
    self.tokens_used = tokens_used
    self.save!
    board
  end

  def prompt_image_name(item_name)
    item_name.downcase!
    # Strip out any non-alphanumeric characters
    item_name.gsub(/[^a-z ]/i, "")
    item_name
  end
end
