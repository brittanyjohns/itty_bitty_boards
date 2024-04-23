class MenusController < ApplicationController
  before_action :authenticate_user!

  before_action :set_menu, only: %i[ show edit update destroy ]

  # GET /menus or /menus.json
  def index
    @menus = current_user.menus.order(created_at: :desc).page params[:page]
  end

  # GET /menus/1 or /menus/1.json
  def show
    @new_menu_doc = Doc.new
    @new_menu_doc.documentable = @menu
    @board = @menu.boards.last
    # unless params[:menu_page]
    #   redirect_to @board if @board
    #   return
    # end
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
    unless @board
      redirect_to menu_url(@menu), notice: "No board found for this menu."
      return
    end
    if current_user.tokens < 1
      redirect_to menu_url(@menu), notice: "Not enough tokens to re-run image description job."
      return
    end
    if @board.cost >= @menu.token_limit
      redirect_to menu_url(@menu), notice: "This menu has already used all of its tokens."
      return
    end
    @menu.rerun_image_description_job
    redirect_to menu_url(@menu), notice: "Re-running image description job."
  end

  # POST /menus or /menus.json
  def create
    @menu = current_user.menus.new(menu_params)
    @menu.user = current_user

    respond_to do |format|
      if @menu.save
        @board = @menu.boards.create!(user: current_user, name: @menu.name, token_limit: @menu.token_limit)
        @menu.run_image_description_job(@board.id)
        puts "Menu created and image description job started."
        # format.turbo_stream
        format.html { redirect_to @board, notice: "Menu is generating." }
        format.json { render :show, status: :created, location: @menu }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @menu.errors, status: :unprocessable_entity }
      end
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
                                  docs_attributes: [:id, :raw, :image, :_destroy, :user_id, :source_type])
    end
end
