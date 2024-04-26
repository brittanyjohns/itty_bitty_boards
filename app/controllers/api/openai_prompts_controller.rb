class API::OpenaiPromptsController < API::ApplicationController
  before_action :set_openai_prompt, only: %i[ show edit update destroy ]

  # GET /openai_prompts or /openai_prompts.json
  def index
    @openai_prompts = OpenaiPrompt.all
  end

  # GET /openai_prompts/1 or /openai_prompts/1.json
  def show
  end

  # GET /openai_prompts/new
  def new
    @openai_prompt = OpenaiPrompt.new
  end

  # GET /openai_prompts/1/edit
  def edit
  end

  # POST /openai_prompts or /openai_prompts.json
  def create
    @openai_prompt = current_user.openai_prompts.new(openai_prompt_params)
    @openai_prompt.token_limit = openai_prompt_params[:token_limit] || 10
    # Temporarily set send_now to true
    @openai_prompt.send_now = true

    respond_to do |format|
      if @openai_prompt.save
        @board = @openai_prompt.boards.create!(user: current_user, name: @openai_prompt.prompt_text, token_limit: @openai_prompt.token_limit, description: @openai_prompt.revised_prompt)
        CreateScenarioBoardJob.perform_async(@openai_prompt.id)

        format.json { render json: @board.api_view_with_images(current_user), status: :created }
        format.turbo_stream
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @openai_prompt.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /openai_prompts/1 or /openai_prompts/1.json
  def update
    respond_to do |format|
      if @openai_prompt.update(openai_prompt_params)
        format.html { redirect_to openai_prompt_url(@openai_prompt), notice: "Openai prompt was successfully updated." }
        format.json { render :show, status: :ok, location: @openai_prompt }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @openai_prompt.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /openai_prompts/1 or /openai_prompts/1.json
  def destroy
    @openai_prompt.destroy!

    respond_to do |format|
      format.html { redirect_to openai_prompts_url, notice: "Openai prompt was successfully destroyed." }
      format.json { head :no_content }
    end
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_openai_prompt
    @openai_prompt = OpenaiPrompt.find(params[:id])
  end

  # Only allow a list of trusted parameters through.
  def openai_prompt_params
    params.require(:openai_prompt).permit(:user_id, :prompt_text, :revised_prompt, :send_now, :deleted_at, :sent_at, :private, :response_type, :age_range, :number_of_images, :token_limit)
  end
end
