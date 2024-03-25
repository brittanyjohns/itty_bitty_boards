class ImagesController < ApplicationController
  before_action :authenticate_user!

  before_action :set_image, only: %i[ show edit update destroy ]

  # GET /images or /images.json
  def index
    if params[:user_images_only] == "1"
      @images = Image.searchable_images_for(current_user, true)
    else
      @images = Image.searchable_images_for(current_user)
    end

    if params[:query].present?
      @images = @images.where("label ILIKE ?", "%#{params[:query]}%").order(label: :asc).page params[:page]
    else
      @images = @images.order(label: :asc).page params[:page]
    end
    if turbo_frame_request?
      render partial: "images", locals: { images: @images }
    else
      render :index
    end
  end

  def menu
    if params[:user_images_only] == "1"
      @images = Image.searchable_menu_items_for(current_user).order(label: :asc).page params[:page]
    else
      @images = Image.searchable_menu_items_for(nil).order(label: :asc).page params[:page]
      if current_user.admin?
        @images = Image.menu_images.order(label: :asc).page params[:page]
      end
    end

    if params[:query].present?
      @images = @images.searchable_menu_items_for(current_user).where("label ILIKE ?", "%#{params[:query]}%").order(label: :asc).page params[:page]
    else
      @images = @images.searchable_menu_items_for(current_user).order(label: :asc).page params[:page]
    end
    if turbo_frame_request?
      render partial: "images", locals: { images: @images }
    else
      render :menu_images
    end
  end

  # GET /images/1 or /images/1.json
  def show
    @user_image_boards = @image.boards.where(user_id: current_user.id)
    @new_image_doc = @image.docs.new
    @current_doc = @image.display_doc(current_user)
    @status = @image.status
    if @image.finished?
      @ready_to_send = true
    elsif @image.generating?
      @ready_to_send = false
    else
      @ready_to_send = false
    end
    @image_docs = @image.docs.for_user(current_user).excluding(@current_doc).order(created_at: :desc)
  end

  # GET /images/new
  def new
    @image = Image.new
  end

  # GET /images/1/edit
  def edit
  end

  # POST /images or /images.json
  def create
    @image = Image.new(image_params)
    @image.user = current_user
    @image.private = true

    respond_to do |format|
      if @image.save
        format.json { render :show, status: :created, location: @image }
        # @doc = @image.docs.last
        # UserDoc.create(user_id: current_user.id, doc_id: @doc.id, image_id: @image.id)
        format.html { redirect_to image_url(@image), notice: "Image was successfully created." }
        format.json { render :show, status: :created, location: @image }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @image.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /images/1 or /images/1.json
  def update
    respond_to do |format|
      if @image.update(image_params)
        format.html { redirect_to image_url(@image), notice: "Image was successfully updated." }
        format.json { render :show, status: :ok, location: @image }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @image.errors, status: :unprocessable_entity }
      end
    end
  end

  def generate
    @image = Image.find(params[:id])
    @image.update(status: "generating")
    GenerateImageJob.perform_async(@image.id, current_user.id, params[:image_prompt])
    sleep 2
    current_user.remove_tokens(1)
    render json: { status: "success", redirect_url: images_url, notice: "Image was successfully cropped & saved." } 
  end

  def find_or_create
    generate_image = params['generate_image'] == "1"
    label = params['label']&.downcase
    @image = Image.find_by(label: label, user_id: current_user.id)
    @image = Image.public_img.find_by(label: label) unless @image
    @found_image = @image
    @image = Image.create(label: label, private: false) unless @image
    @board = Board.find_by(id: params[:board_id]) if params[:board_id].present?

    @board.add_image(@image.id) if @board
    if @found_image
      notice = "Image found!"
      @found_image.update(status: "finished") unless @found_image.finished?
      run_generate if generate_image
    else
      if current_user.tokens > 0 && generate_image
        notice = "Generating image..."
        run_generate
      elsif !generate_image
        notice = "Image created! Remember you can always upload your own image or generate one later."
      else
        notice = "You don't have enough tokens to generate an image."
      end
    end
    if !@found_image || @found_image&.docs.none?
      puts "New Image or no docs"
      limit = current_user.admin? ? 10 : 5
      GetSymbolsJob.perform_async([@image.id], limit)
      notice += " Creating #{limit} #{'symbol'.pluralize(limit)} for image."      
    end

    respond_to do |format|
      format.json { render :show, status: :created, location: @image }
      format.turbo_stream
    end
    # redirect_back_or_to image_url(@image), notice: notice
  end

  def add_to_board
    @image = Image.find(params[:id])
    @board = Board.find(params[:board_id])
    @board.add_image(@image.id)
    redirect_back_or_to image_url(@image), notice: "Image added to board."
  end

  def create_symbol
    @image = Image.find(params[:id])
    limit = current_user.admin? ? 10 : 1
    GetSymbolsJob.perform_async([@image.id], limit)
    redirect_back_or_to image_url(@image), notice: "Creating #{limit} #{'symbol'.pluralize(limit)} for image '#{@image.label}'."
  end

  def run_generate
    return if current_user.tokens < 1
    @image.update(status: "generating")
    GenerateImageJob.perform_async(@image.id, current_user.id)
    current_user.remove_tokens(1)
    @board.add_to_cost(1) if @board
  end

  def create_audio
    @image = Image.find(params[:id])
    voice = params[:voice] || "alloy"
    @audio = @image.create_audio_from_text(@image.label, voice)
    redirect_back_or_to image_url(@image), notice: "Audio created."
  end

  def remove_audio
    @image = Image.find(params[:id])
    @image.audio_files.find(params[:audio_id]).purge
    redirect_back_or_to image_url(@image), notice: "Audio removed."
  end

  # DELETE /images/1 or /images/1.json
  def destroy
    @image.destroy!

    respond_to do |format|
      format.html { redirect_to images_url, notice: "Image was successfully destroyed." }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_image
      @image = Image.find(params[:id])
    end

    # Only allow a list of trusted parameters through.
    def image_params
      params.require(:image).permit(:label, :image_prompt, :private, :user_id, :status, :error)
    end
end
