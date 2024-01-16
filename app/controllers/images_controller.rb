class ImagesController < ApplicationController
  before_action :authenticate_user!

  before_action :set_image, only: %i[ show edit update destroy ]

  # GET /images or /images.json
  def index
    if params[:user_images_only] == "1"
      @images = current_user.images.includes(docs: :image_attachment).order(created_at: :desc).page params[:page]
    else
      @images = Image.includes(docs: :image_attachment).searchable_images_for(current_user).order(created_at: :desc).page params[:page]
    end

    if params[:query].present?
      @images = @images.searchable_images_for(current_user).where("label ILIKE ?", "%#{params[:query]}%").order(updated_at: :desc).page params[:page]
    else
      @images = @images.searchable_images_for(current_user).order(updated_at: :desc).page params[:page]
    end
    if turbo_frame_request?
      render partial: "images", locals: { images: @images }
    else
      render :index
    end
  end

  # GET /images/1 or /images/1.json
  def show
    @user_image_boards = @image.boards.where(user_id: current_user.id)
    puts "\n\n****@user_image_boards: #{@user_image_boards}\n\n"
    @new_image_doc = @image.docs.new
    @status = @image.status
    if @image.finished?
      @ready_to_send = true
    elsif @image.generating?
      @ready_to_send = false
    else
      @ready_to_send = false
    end
    @image_docs = @image.docs.for_user(current_user).order(created_at: :desc)
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
    puts "\n\n****image_params: #{image_params}\n\n"

    respond_to do |format|
      if @image.save
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
    if params[:image_prompt].present?
      puts "Updating image_prompt to: #{params[:image_prompt]}\n"
      # @image.update(image_prompt: params[:image_prompt])
      @image.image_prompt = params[:image_prompt]
    end
    puts "PARAMS: #{params}\n "
    GenerateImageJob.perform_async(@image.id, current_user.id, params[:image_prompt])
    sleep 2
    current_user.remove_tokens(1)
    render json: { status: "success", redirect_url: images_url, notice: "Image was successfully cropped & saved." } 
  end

  def find_or_create
    puts "PARAMS: #{params}\n"
    label = params['label']&.downcase
    puts "LABEL: #{label}\n"
    @image = Image.find_by(label: label, user_id: current_user.id)
    @image = Image.find_by(label: label, private: false) unless @image
    @found_image = @image
    @image = Image.create(label: label, private: false) unless @image
    @board = Board.find_by(id: params[:board_id]) if params[:board_id].present?
    @board.add_image(@image.id) if @board
    if @found_image
      notice = "Image found!"
      @found_image.update(status: "finished") unless @found_image.finished?
    else
      if current_user.tokens > 0
        notice = "Generating image..."
        GenerateImageJob.perform_async(@image.id, current_user.id)
        sleep 2
        current_user.remove_tokens(1)
      end
    end
    redirect_back_or_to image_url(@image), notice: notice
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
