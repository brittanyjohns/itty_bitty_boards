class ScenariosController < ApplicationController
  before_action :set_scenario, only: %i[ show edit update destroy ]

  # GET /scenarios or /scenarios.json
  def index
    @scenarios = Scenario.all
  end

  # GET /scenarios/1 or /scenarios/1.json
  def show
  end

  # GET /scenarios/new
  def new
    @scenario = Scenario.new
  end

  # GET /scenarios/1/edit
  def edit
  end

  # POST /scenarios or /scenarios.json
  def create
    name = scenario_params[:name]
    age_range = scenario_params[:age_range]
    initial_description = scenario_params[:initial_description]
    puts "name: #{name}\nage_range: #{age_range}\ninitial_description: #{initial_description}"
    @scenario = Scenario.create(name: name, age_range: age_range, initial_description: initial_description, user_id: current_user&.id)
    # Step 1: Ask the first follow-up question
    question_1 = generate_first_question(@scenario)
    @scenario.questions = { "question_1" => question_1 }
    respond_to do |format|
      if @scenario.save
        format.html { redirect_to scenario_url(@scenario), notice: "Scenario was successfully created." }
        format.json { render :show, status: :created, location: @scenario }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @scenario.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /scenarios/1 or /scenarios/1.json
  def update
    @scenario = Scenario.find(params[:id])
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
    answer_1 = scenario_params[:answers]
    @scenario.answers = { "answer_1" => answer_1 }
    @scenario.save

    # Step 2: Ask the second follow-up question using the first answer
    question_2 = generate_second_question(@scenario)
    @scenario.questions["question_2"] = question_2

    respond_to do |format|
      if @scenario.save
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
      format.html { redirect_to scenarios_url, notice: "Scenario was successfully destroyed." }
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
    params.require(:scenario).permit(:questions, :answers, :name, :initial_description, :age_range, :user_id, :status, :word_list, :finalize)
  end

  def generate_first_question(scenario)
    initial_scenario = scenario.initial_description
    puts "initial_scenario: #{initial_scenario}"
    age_range = scenario.age_range
    client = OpenAI::Client.new(access_token: ENV["OPENAI_ACCESS_TOKEN"])

    prompt = <<~PROMPT
      The scenario is name: #{scenario.name} and was described as: #{initial_scenario}. The age range of the person in the given scenario is: #{age_range}.
        Please ask one follow-up question to gather more details about this scenario.
    PROMPT

    response = client.chat(
      parameters: {
        model: "gpt-4",
        messages: [
          { role: "system", content: system_message },
          { role: "user", content: prompt },
        ],
        max_tokens: 50,
        temperature: 0.7,
      },
    )

    response.dig("choices", 0, "message", "content").strip
  end

  def generate_second_question(scenario)
    initial_scenario = scenario.initial_description
    age_range = scenario.age_range
    answer_1 = scenario.answers["answer_1"]
    question_1 = scenario.questions["question_1"]

    client = OpenAI::Client.new(access_token: ENV["OPENAI_ACCESS_TOKEN"])

    prompt = <<~PROMPT
      The scenario is: #{scenario}. The age range is: #{age_range}.
        Based on the user's answer: #{answer_1} to the question #{question_1}.
        , please ask another follow-up question to gather more details about this scenario.
    PROMPT

    response = client.chat(
      parameters: {
        model: "gpt-4",
        messages: [
          { role: "system", content: system_message },
          { role: "user", content: prompt },
        ],
        max_tokens: 50,
        temperature: 0.7,
      },
    )

    response.dig("choices", 0, "message", "content").strip
  end

  def generate_word_list(scenario)
    initial_scenario = scenario.initial_description
    age_range = scenario.age_range
    scenario.answers ||= {}

    answer_1 = scenario.answers["answer_1"]
    question_1 = scenario.questions["question_1"]
    question_2 = scenario.questions["question_2"]
    answer_2 = scenario.answers["answer_2"]

    client = OpenAI::Client.new(access_token: ENV["OPENAI_ACCESS_TOKEN"])

    prompt = <<~PROMPT
      The scenario is: #{initial_scenario}. The age range is: #{age_range}.
        Based on the following details: 
        #{question_1}: #{answer_1},
        #{question_2}: #{answer_2},
        please return an array of words that people would likely use in conversation during this scenario.
    PROMPT

    response = client.chat(
      parameters: {
        model: "gpt-4",
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
