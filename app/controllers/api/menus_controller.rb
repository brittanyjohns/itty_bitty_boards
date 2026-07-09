class API::MenusController < API::ApplicationController
  before_action :set_menu, only: %i[ show edit update destroy ]
  before_action :check_board_create_permissions, only: %i[ create ]

  # Default image budget when the client sends no/garbage token_limit.
  IMAGE_BUDGET_DEFAULT = 10

  # GET /menus or /menus.json
  def index
    @current_user = current_user
    @menus = @current_user.menus.user_defined.order(created_at: :desc).page params[:page]
    if @current_user.admin?
      @menus = Menu.all.order(created_at: :desc).page params[:page]
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
    unless current_user.admin? || current_user.id == @menu.user_id
      render json: { error: "You do not have permission to rerun this menu." }, status: :forbidden
      return
    end

    # A rerun re-extracts (vision call) and regenerates images, so it costs
    # the same as a fresh create: flat fee + the image budget.
    image_budget = sanitize_image_budget(params[:token_limit].presence || @menu.token_limit)
    return unless check_credits!(feature_key: "menu_create", feature_name: "AI Menu Re-run", amount: menu_build_cost(image_budget))

    @menu.update(token_limit: image_budget) if @menu.token_limit != image_budget
    @board = @menu.boards.last
    @board = @menu.boards.new(user: current_user, name: @menu.name, predefined: false, display_image_url: @menu.docs.last.display_url, large_screen_columns: 8, medium_screen_columns: 6, small_screen_columns: 4, board_type: "menu", parent: @menu) if @board.nil?
    @board.token_limit = image_budget
    stash_menu_credit_reservation(@board, image_budget)
    @board.generate_unique_slug
    @board.status = "pending"
    unless @board.save
      Rails.logger.error "Failed to create board for menu: #{@menu.id} - #{@menu.name}"
      render json: { error: "Failed to create board for menu. #{@board.errors.full_messages.join(", ")}" }, status: :unprocessable_content
      return
    end

    @board.update(board_type: "menu")
    result = @menu.enhance_image_description(@board.id)
    # Extraction ran inline and produced nothing — the user gets the whole
    # spend back (create's async path does the same in EnhanceImageDescriptionJob).
    Menus::CreditRefunds.refund_all!(@board) if result.nil?
    render json: @menu.api_view(current_user), status: 200
  end

  # POST /menus or /menus.json
  def create
    image_budget = sanitize_image_budget(menu_params[:token_limit])
    return unless check_credits!(feature_key: "menu_create", feature_name: "AI Menu Creation", amount: menu_build_cost(image_budget))
    @current_user = current_user
    @menu = @current_user.menus.new
    @menu.user = current_user
    menu_name = menu_params[:name]
    screen_size = params[:screen_size] || "lg"
    @menu.name = menu_name
    @menu.predefined = menu_params[:predefined] || false
    @menu.token_limit = image_budget
    @menu.user = @current_user
    @menu.menu_image.attach(menu_params[:docs][:image]) if menu_params[:docs] && menu_params[:docs][:image]
    unless @menu.save
      render json: @menu.errors, status: :unprocessable_content
      return
    end
    doc = @menu.docs.new(menu_params[:docs])
    doc.user = @current_user
    if doc.save
      @board = @menu.boards.new(user: current_user, name: @menu.name, token_limit: @menu.token_limit, predefined: @menu.predefined, display_image_url: doc.display_url, large_screen_columns: 8, medium_screen_columns: 6, small_screen_columns: 4, board_type: "menu", parent: @menu, voice: "polly:kevin", language: "en")
      stash_menu_credit_reservation(@board, image_budget)
      @board.generate_unique_slug
      @board.status = "pending"
      @board.preview_image.attach(menu_params[:docs][:image]) if menu_params[:docs] && menu_params[:docs][:image]
      if @board.nil?
        Rails.logger.error "Failed to create board for menu: #{@menu.id} - #{@menu.name}"
        render json: { error: "Failed to create board for menu." }, status: :unprocessable_content
        return
      end
      unless @board.save
        Rails.logger.error "Failed to save board for menu: #{@menu.id} - #{@menu.name} - Errors: #{@board.errors.full_messages.join(", ")}"
        render json: { error: "Failed to save board for menu. #{@board.errors.full_messages.join(", ")}" }, status: :unprocessable_content
        return
      end
      @menu.run_image_description_job(@board.id, screen_size)
      # render json: @menu.api_view(current_user), status: :created
      # @menu.enhance_image_description(@board.id)
      # Rails.logger.debug "Image description job started for menu: #{@menu.id} - #{@menu.name} - Board: #{@board.id} - #{@board.name}"
      @menu_with_display_doc = {
        id: @menu.id,
        name: @menu.name,
        description: @menu.description,
        boardId: @board.id,
        board: @board.api_view(@current_user),
        displayImage: @board.display_image_url,
        status: @board.status,
        predefined: @menu.predefined,
        preview_image_url: @menu.menu_image_url,
        user_id: @menu.user_id,
        can_edit: @current_user.admin? || @current_user.id == @menu.user_id,
      }
      render json: @menu_with_display_doc, status: :created
    else
      render json: @menu.errors, status: :unprocessable_content
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
      render json: @menu.errors, status: :unprocessable_content
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

  # `token_limit` on a menu means "max AI images to generate for this build".
  # Clamp to [0, MENU_MAX_IMAGES]; 0 is a legitimate pick (tiles reuse
  # existing art only, nothing is sent to OpenAI).
  def sanitize_image_budget(raw)
    budget = begin
      Integer(raw)
    rescue ArgumentError, TypeError
      IMAGE_BUDGET_DEFAULT
    end
    budget.clamp(0, max_image_budget)
  end

  def max_image_budget
    (ENV["MENU_MAX_IMAGES"] || 30).to_i
  end

  # Total up-front spend: flat extraction fee + the picked image budget.
  def menu_build_cost(image_budget)
    CreditService.cost_for("menu_create") + image_budget * CreditService.cost_for("menu_image")
  end

  # Record the spend txn + budget on the board so the async build can cap
  # generation and refund whatever it doesn't deliver (Menus::CreditRefunds).
  # Admins aren't charged (check_credits! bypasses), so no reservation —
  # the budget still caps generation via board.token_limit.
  def stash_menu_credit_reservation(board, image_budget)
    return unless @credit_spend_transaction
    board.settings = (board.settings || {}).merge(
      "menu_credit" => {
        "txn_id" => @credit_spend_transaction.id,
        "per_image" => CreditService.cost_for("menu_image"),
        "reserved" => image_budget,
      },
    )
  end

  # Only allow a list of trusted parameters through.
  def menu_params
    # :user_id is intentionally NOT permitted (top-level or on the nested docs)
    # — ownership is assigned server-side (@menu.user / doc.user = current_user
    # in #create), so a client can't set or reassign ownership via create/update
    # mass-assignment (#27).
    permitted = params.require(:menu).permit(:name, :description, :token_limit, :predefined,
                                             docs: [:id, :raw, :image, :_destroy, :source_type])
    # `predefined` promotes a menu into the curated/admin pool — admin-only.
    # Strip it for everyone else so a regular user can't self-promote (#27).
    permitted.delete(:predefined) unless current_user&.admin?
    permitted
  end

  def check_board_create_permissions
    unless current_user
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
    if current_user.at_board_limit?
      render json: { error: "Maximum number of boards reached. Please upgrade to add more." }, status: :unprocessable_content
      return
    end
    return true
  end
end
