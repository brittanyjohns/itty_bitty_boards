class MenusController < ApplicationController
  before_action :set_menu, only: %i[ show edit update destroy ]

  # GET /menus or /menus.json
  def index
    @menus = current_user.menus.order(created_at: :desc).page params[:page]
  end

  # GET /menus/1 or /menus/1.json
  def show
    @new_menu_doc = Doc.new
    @new_menu_doc.documentable = @menu
  end

  # GET /menus/new
  def new
    @menu = current_user.menus.new
    @new_menu_doc = @menu.docs.new
  end

  # GET /menus/1/edit
  def edit
  end

  # POST /menus or /menus.json
  def create
    @menu = current_user.menus.new(menu_params)
    @menu.user = current_user
    doc_params = menu_params[:docs_attributes]["0"]
    puts "doc_params: #{doc_params}\n"
    # @doc = @menu.docs.new(doc_params)
    puts "doc: #{@doc}\n"
    # @doc.image.attach(doc_params[:image]) if doc_params[:image]

    respond_to do |format|
      if @menu.save
        @menu.run_image_description_job
        format.html { redirect_to menu_url(@menu), notice: "Menu was successfully created." }
        format.json { render :show, status: :created, location: @menu }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @menu.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /menus/1 or /menus/1.json
  def update
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
      params.require(:menu).permit(:user_id, :name, :description, docs_attributes: [:id, :raw_text, :image, :_destroy, :user_id])
    end
end
