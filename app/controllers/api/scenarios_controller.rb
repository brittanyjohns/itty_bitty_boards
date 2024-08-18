class API::ScenariosController < API::ApplicationController
  before_action :set_scenario, only: %i[ show edit update destroy ]

  # GET /scenarios or /scenarios.json
  def index
    @scenarios = OpenaiPrompt.all
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
    @scenario = current_user.openai_prompts.new(scenario_params)
    @scenario.token_limit = scenario_params[:token_limit] || 10
    # Temporarily set send_now to true
    @scenario.send_now = true
    board_name = params[:name]
    puts "board_name: #{board_name}"

    respond_to do |format|
      if @scenario.save
        @board = @scenario.boards.create!(user: current_user, name: board_name, token_limit: @scenario.token_limit, description: @scenario.revised_prompt)
        CreateScenarioBoardJob.perform_async(@scenario.id)
        format.json { render json: @scenario.api_view_with_images(current_user), status: :created }
        format.turbo_stream
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @scenario.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /scenarios/1 or /scenarios/1.json
  def update
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
      format.html { redirect_to scenarios_url, notice: "Scenario was successfully destroyed." }
      format.json { head :no_content }
    end
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_scenario
    @scenario = OpenaiPrompt.find(params[:id])
  end

  # Only allow a list of trusted parameters through.
  def scenario_params
    params.require(:scenario).permit(:name, :user_id, :prompt_text, :revised_prompt, :send_now, :deleted_at, :sent_at, :private, :response_type, :age_range, :number_of_images, :token_limit)
  end
end
