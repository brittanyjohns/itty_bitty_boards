class API::MenusController < API::ApplicationController
  before_action :set_menu, only: %i[ show edit update destroy ]

  # GET /menus or /menus.json
  def index
    @current_user = current_user
    @menus = @current_user.menus.user_defined.order(created_at: :desc).page params[:page]
    if @current_user.admin?
      @menus = Menu.user_defined.order(created_at: :desc).page params[:page]
    end
    @menus_with_display_docs = @menus.map do |menu|
      {
        id: menu.id,
        name: menu.name,
        description: menu.description,
        boardId: menu.boards.last&.id,
        user_id: menu.user_id,
        displayImage: menu.docs.last&.image&.url,
        can_edit: @current_user.admin? || @current_user.id == menu.user_id,
        predefined: menu.predefined,
      }
    end
    @predefined_menus = Menu.predefined.order(created_at: :desc).map do |menu|
      {
        id: menu.id,
        name: menu.name,
        description: menu.description,
        boardId: menu.boards.last&.id,
        user_id: menu.user_id,
        displayImage: menu.docs.last&.image&.url,
        can_edit: @current_user.admin? || @current_user.id == menu.user_id,
        predefined: menu.predefined,
      }
    end
    render json: { user: @menus_with_display_docs, predefined: @predefined_menus }
  end

  # GET /menus/1 or /menus/1.json
  def show
    render json: @menu.api_view(current_user)
  end

  # GET /menus/new
  def new
    @menu = current_user.menus.new
    @new_menu_doc = @menu.docs.new
  end

  # GET /menus/1/edit
  def edit
    @doc = @menu.docs.last
  end

  def rerun
    @menu = Menu.find(params[:id])
    @board = @menu.boards.last
    message = "Re-running image description job."
    unless @board
      message = "No board found for this menu."
      render json: { message: message }, status: :unprocessable_entity
      # redirect_to menu_url(@menu), notice: "No board found for this menu."
      return
    end
    if current_user.tokens < 1
      message = "Not enough tokens to re-run image description job."
      render json: { error: message }, status: :unprocessable_entity
      # redirect_to menu_url(@menu), notice: "Not enough tokens to re-run image description job."
      return
    end
    if @board.cost >= @menu.token_limit
      Rails.logger.info "Board cost: #{@board.cost} >= Menu token limit: #{@menu.token_limit}"
      message = "This menu has already used all of its tokens. Menu token limit: #{@menu.token_limit}"
      render json: { error: message }, status: :unprocessable_entity
      # redirect_to menu_url(@menu), notice: "This menu has already used all of its tokens."
      return
    end
    @menu.rerun_image_description_job
    render json: @menu.api_view(current_user), status: 200
    # redirect_to menu_url(@menu), notice: "Re-running image description job."
  end

  # POST /menus or /menus.json
  def create
    @current_user = current_user
    @menu = @current_user.menus.new
    @menu.user = current_user
    menu_name = menu_params[:name]
    @menu.name = menu_name
    @menu.description = menu_params[:description]
    @menu.token_limit = menu_params[:token_limit] || 10
    @menu.user = @current_user
    unless @menu.save
      render json: @menu.errors, status: :unprocessable_entity
      return
    end
    doc = @menu.docs.new(menu_params[:docs])
    doc.user = @current_user
    doc.processed = true
    doc.raw = params[:menu][:description]
    if doc.save
      @board = @menu.boards.create!(user: current_user, name: @menu.name, token_limit: @menu.token_limit, predefined: @menu.predefined)
      @menu.run_image_description_job(@board.id)
      @menu_with_display_doc = {
        id: @menu.id,
        name: @menu.name,
        description: @menu.description,
        boardId: @board.id,
        displayImage: @menu.docs.last&.image&.url,
        predefined: @menu.predefined,
        user_id: @menu.user_id,
        can_edit: @current_user.admin? || @current_user.id == @menu.user_id,
      }
      render json: @menu_with_display_doc, status: 200
    else
      render json: @menu.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /menus/1 or /menus/1.json
  def update
    unless current_user.admin? || current_user.id == @menu.user_id
      render json: { error: "You do not have permission to update this menu." }, status: :unauthorized
      return
    end
    if @menu.update(menu_params)
      render json: @menu, status: :ok
    else
      render json: @menu.errors, status: :unprocessable_entity
    end
  end

  # DELETE /menus/1 or /menus/1.json
  def destroy
    @menu.destroy!

    respond_to do |format|
      format.json { head :no_content }
    end
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_menu
    @menu = Menu.includes(:boards, :docs).find(params[:id])
  end

  # Only allow a list of trusted parameters through.
  def menu_params
    params.require(:menu).permit(:user_id, :name, :description, :token_limit,
                                 docs: [:id, :raw, :image, :_destroy, :user_id, :source_type])
  end
end
