class API::ScenariosController < API::ApplicationController
  before_action :set_scenario, only: %i[ show edit update destroy finalize answer ]
  GPT_4_MODEL = "gpt-4o"
  # GET /scenarios or /scenarios.json
  def index
    @scenarios = Scenario.all
    render json: @scenarios.map { |scenario| scenario.api_view_with_images(current_user) }
  end

  # GET /scenarios/1 or /scenarios/1.json
  def show
    render json: @scenario.api_view_with_images(current_user)
  end

  # GET /scenarios/new
  def new
    @scenario = OpenaiPrompt.new
  end

  # GET /scenarios/1/edit
  def edit
  end

  # POST /scenarios or /scenarios.json
  def create
    @scenario = current_user.scenarios.new(scenario_params)
    @scenario.token_limit = scenario_params[:token_limit] || 10
    # Temporarily set send_now to true
    board_name = params[:name]
    puts "board_name: #{board_name}"
    name = scenario_params[:name]
    age_range = scenario_params[:age_range]
    puts "PARAMS: #{scenario_params}"
    initial_description = params[:prompt_text]
    if initial_description.blank?
      render json: { error: "Initial description cannot be blank" }, status: :unprocessable_entity
      return
    end
    token_limit = params[:token_limit] || 10

    number_of_images = params[:number_of_images] || 10

    @scenario.name = name
    @scenario.age_range = age_range
    @scenario.initial_description = initial_description
    @scenario.send_now = true
    @scenario.token_limit = token_limit
    @scenario.number_of_images = number_of_images

    # Step 1: Ask the first follow-up question
    question_1 = generate_first_question(@scenario)
    @scenario.questions = { "question_1" => question_1 }
    respond_to do |format|
      if @scenario.save
        # @board = @open_prompt.boards.create!(user: current_user, name: board_name, token_limit: @scenario.token_limit, description: @scenario.revised_prompt)
        # CreateScenarioBoardJob.perform_async(@open_prompt.id)
        format.json { render json: @scenario, status: :created }
      else
        format.json { render json: @scenario.errors, status: :unprocessable_entity }
      end
    end
  end

  def answer
    answer = params[:answer]
    if answer.blank?
      render json: { error: "Answer cannot be blank" }, status: :unprocessable_entity
      return
    end
    question_number = params[:question_number]

    question_key = "question_#{question_number}"
    question_1 = @scenario.questions[question_key]
    @scenario.answers = { question_key => answer }
    @scenario.save
    question_2 = generate_second_question(@scenario)
    @scenario.questions["question_2"] = question_2
    @scenario.save
    render json: @scenario.api_view_with_images(current_user)
  end

  def finalize
    # puts "Finalizing scenario #{params}"
    # @scenario = Scenario.find(params[:id])
    answer = params[:answer]
    question_number = params[:question_number]

    question_key = "question_#{question_number}"
    question = @scenario.questions[question_key]
    @scenario.answers[question_key] = answer
    @scenario.save

    word_list = generate_word_list(@scenario)
    updated_word_list = @scenario.transform_word_list_response(word_list)
    @scenario.word_list = updated_word_list
    name = @scenario.name
    initial_description = @scenario.initial_description
    token_limit = @scenario.token_limit
    user_id = @scenario.user_id

    board = Board.create!(user: current_user, name: name, token_limit: token_limit, description: initial_description, parent_id: user_id, parent_type: "User", board_type: "scenario")

    @scenario.board_id = board.id
    @scenario.save
    CreateScenarioBoardJob.perform_async(@scenario.id)
    sleep(10)
    render json: @scenario.api_view_with_images(current_user)
  end

  # PATCH/PUT /scenarios/1 or /scenarios/1.json
  def update
    if scenario_params[:finalize]
      puts "Finalizing scenario"
      word_list = generate_word_list(@scenario)
      @scenario.word_list = word_list
      @scenario.save
      respond_to do |format|
        format.html { redirect_to scenario_url(@scenario), notice: "Scenario was successfully updated." }
        format.json { render :show, status: :ok, location: @scenario }
      end
      return
    end
    # answer_1 = scenario_params[:answers]
    # @scenario.answers = { "question_1" => answer_1 }
    # @scenario.save

    # # Step 2: Ask the second follow-up question using the first answer
    # question_2 = generate_second_question(@scenario)
    # @scenario.questions["question_2"] = question_2

    respond_to do |format|
      if @scenario.update(scenario_params)
        format.html { redirect_to scenario_url(@scenario), notice: "Scenario was successfully updated." }
        format.json { render :show, status: :ok, location: @scenario }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @scenario.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /scenarios/1 or /scenarios/1.json
  def destroy
    @scenario.destroy!

    respond_to do |format|
      format.json { head :no_content }
    end
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_scenario
    @scenario = Scenario.find(params[:id])
  end

  # Only allow a list of trusted parameters through.
  def scenario_params
    params.require(:scenario).permit(:name, :user_id, :prompt_text, :revised_prompt, :send_now,
                                     :deleted_at, :sent_at, :private, :response_type, :age_range, :number_of_images, :token_limit,
                                     :initial_description, :questions, :answers, :status, :word_list, :finalize)
  end

  def generate_first_question(scenario)
    initial_scenario = scenario.initial_description
    age_range = scenario.age_range
    client = OpenAI::Client.new(access_token: ENV["OPENAI_ACCESS_TOKEN"])

    prompt = <<~PROMPT
      The scenario is name: #{scenario.name} and was described as: #{initial_scenario}. The age range of the person in the given scenario is: #{age_range}.
        Please ask one follow-up question to gather more details about this scenario and the person in it.
    PROMPT

    response = client.chat(
      parameters: {
        model: GPT_4_MODEL,
        messages: [
          { role: "system", content: system_message },
          { role: "user", content: prompt },
        ],
        max_tokens: 100,
        temperature: 0.7,
      },
    )

    response.dig("choices", 0, "message", "content").strip
  end

  def generate_second_question(scenario)
    initial_scenario = scenario.initial_description
    age_range = scenario.age_range
    answer_1 = scenario.answers["question_1"]
    question_1 = scenario.questions["question_1"]
    name = scenario.name

    client = OpenAI::Client.new(access_token: ENV["OPENAI_ACCESS_TOKEN"])

    prompt = <<~PROMPT
      The scenario is name: #{scenario.name} and is described as: #{initial_scenario}. The age range is: #{age_range}.
        Based on the user's answer: #{answer_1} to the question #{question_1}.
        , please ask another follow-up question to gather more details about this scenario.
    PROMPT

    response = client.chat(
      parameters: {
        model: GPT_4_MODEL,
        messages: [
          { role: "system", content: system_message },
          { role: "user", content: prompt },
        ],
        max_tokens: 100,
        temperature: 0.7,
      },
    )

    response.dig("choices", 0, "message", "content").strip
  end

  def generate_word_list(scenario)
    initial_scenario = scenario.initial_description
    age_range = scenario.age_range
    scenario.answers ||= {}
    number_of_images = scenario.number_of_images || 6

    answer_1 = scenario.answers["question_1"]
    question_1 = scenario.questions["question_1"]
    question_2 = scenario.questions["question_2"]
    answer_2 = scenario.answers["question_2"]

    client = OpenAI::Client.new(access_token: ENV["OPENAI_ACCESS_TOKEN"])

    prompt = <<~PROMPT
      The scenario is: #{initial_scenario}. The age range is: #{age_range}.
        Based on the following details: 
        #{question_1}: #{answer_1},
        #{question_2}: #{answer_2},
        please return an array of exactly #{number_of_images} words or short phrases (2 words max) that a #{age_range} year old person would likely use in conversation during this scenario.
    PROMPT

    response = client.chat(
      parameters: {
        model: GPT_4_MODEL,
        messages: [
          { role: "system", content: system_message },
          { role: "user", content: prompt },
        ],
        max_tokens: 100,
        temperature: 0.7,
      },
    )

    response.dig("choices", 0, "message", "content").split(",").map(&:strip)
  end

  def system_message
    "You are a helpful assistant with a friendly personality."
  end
end
