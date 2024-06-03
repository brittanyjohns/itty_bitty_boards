class API::MenusController < API::ApplicationController
  before_action :set_menu, only: %i[ show edit update destroy ]

  # GET /menus or /menus.json
  def index
    @menus = current_user.menus.order(created_at: :desc).page params[:page]
    @menus_with_display_docs = @menus.map do |menu|
      {
        id: menu.id,
        name: menu.name,
        description: menu.description,
        boardId: menu.boards.last&.id,
        displayImage: menu.docs.last&.image&.url
      }
    end
    render json: @menus_with_display_docs
  end

  # GET /menus/1 or /menus/1.json
  def show
    @new_menu_doc = Doc.new
    @new_menu_doc.documentable = @menu
    @board = @menu.boards.last
    unless @board
      redirect_to menus_url, notice: "No board found for this menu."
      return
    end
    @board_images = @board.images.map do |image|
      {
        id: image.id,
        label: image.label, 
        src: image.display_image(current_user) ? image.display_image(current_user).url : "https://via.placeholder.com/300x300.png?text=#{image.label_param}",
        audio: image.audio_files.first ? image.audio_files.first.url : nil
      }
    end
    @menu_with_display_doc = {
      id: @menu.id,
      name: @menu.name,
      description: @menu.description,
      boardId: @board.id,
      images: @board_images,
      displayImage: @menu.docs.last.image.url
    }
    render json: @menu_with_display_doc
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
      render json: { message: message }, status: :unprocessable_entity
      # redirect_to menu_url(@menu), notice: "Not enough tokens to re-run image description job."
      return
    end
    if @board.cost >= @menu.token_limit
      Rails.logger.info "Board cost: #{@board.cost} >= Menu token limit: #{@menu.token_limit}"
      message = "This menu has already used all of its tokens."
      render json: { message: message }, status: :unprocessable_entity
      # redirect_to menu_url(@menu), notice: "This menu has already used all of its tokens."
      return
    end
    @menu.rerun_image_description_job
    render json: { message: message }, status: :ok
    # redirect_to menu_url(@menu), notice: "Re-running image description job."
  end

  # POST /menus or /menus.json
  def create
    @menu = current_user.menus.new
    @menu.user = current_user
    puts "PARAMS: #{params}"
    menu_name = menu_params[:name]
    @menu.name = menu_name
    @menu.description = menu_params[:description]
    @menu.token_limit = menu_params[:token_limit] || 10
    @menu.user = current_user
    unless @menu.save
      render json: @menu.errors, status: :unprocessable_entity
      return
    end
    puts "MENU PARAMS: #{menu_params}"
    doc = @menu.docs.new(menu_params[:docs])
    doc.user = current_user
    doc.processed = true
    doc.raw = params[:menu][:description]
    puts "DOC"
    pp doc
    if doc.save
      @board = @menu.boards.create!(user: current_user, name: @menu.name, token_limit: @menu.token_limit)
      @menu.run_image_description_job(@board.id)
      # @menu.enhance_image_description(@board.id)
      @menu_with_display_doc = {
      id: @menu.id,
      name: @menu.name,
      description: @menu.description,
      boardId: @board.id,
      displayImage: @menu.docs.last.image.url
    }
      render json: @menu_with_display_doc, status: :created
    else
      render json: @menu.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /menus/1 or /menus/1.json
  def update
    unless current_user.admin? || current_user.id == @menu.user_id
      redirect_to root_url, notice: "You are not authorized to edit this menu."
      return
    end
    respond_to do |format|
      if @menu.update(menu_params)
        format.html { redirect_to menu_url(@menu), notice: "Menu was successfully updated." }
        format.json { render :show, status: :ok, location: @menu }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @menu.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /menus/1 or /menus/1.json
  def destroy
    @menu.destroy!

    respond_to do |format|
      format.html { redirect_to menus_url, notice: "Menu was successfully destroyed." }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_menu
      @menu = Menu.find(params[:id])
    end

    # Only allow a list of trusted parameters through.
    def menu_params
      params.require(:menu).permit(:user_id, :name, :description, :token_limit,
                                  docs: [:id, :raw, :image, :_destroy, :user_id, :source_type])
    end
end
