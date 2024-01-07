class ImagesController < ApplicationController
  before_action :set_image, only: %i[ show edit update destroy ]

  # GET /images or /images.json
  def index
    if params[:user_images_only] == "1"
      @images = current_user.images.includes(:docs).page params[:page]
    else
      @images = Image.includes(:docs).searchable_images_for(current_user).order(created_at: :desc).page params[:page]
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
    @new_image_doc = @image.docs.new
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
    GenerateImageJob.perform_async(@image.id, current_user.id)
    sleep 2
    redirect_to image_url(@image)
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
      params.require(:image).permit(:label, :image_prompt, :private, :user_id)
    end
end
