class DocsController < ApplicationController
  before_action :authenticate_user!

  before_action :set_doc, only: %i[ show edit update destroy ]

  # GET /docs or /docs.json
  def index
    @docs = Doc.all
  end

  # GET /docs/1 or /docs/1.json
  def show
  end

  # GET /docs/new
  def new
    @doc = Doc.new
  end

  # GET /docs/1/edit
  def edit
  end

  # POST /docs or /docs.json
  def create
    @doc = Doc.new(doc_params)
    @doc.user = current_user
    @documentable = @doc.documentable if @doc.documentable

    respond_to do |format|
      if @doc.save
        if @documentable.is_a?(Menu)
          @documentable.enhance_image_description
        else
          @image = @documentable
          UserDoc.create(user_id: current_user.id, doc_id: @doc.id, image_id: @image.id)
        end
        format.html { redirect_to @doc.documentable, notice: "Doc was successfully created." }
        format.json { render :show, status: :created, location: @doc }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @doc.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /docs/1 or /docs/1.json
  def update
    respond_to do |format|
      if @doc.update(doc_params)
        format.html { redirect_to doc_url(@doc), notice: "Doc was successfully updated." }
        format.json { render :show, status: :ok, location: @doc }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @doc.errors, status: :unprocessable_entity }
      end
    end
  end

  def move
    @doc = Doc.find(params[:id])
    unless current_user&.can_edit?(@doc)
      redirect_back_or_to root_url, notice: "You do not have permission to edit this doc."
    end
    if params[:documentable_type] == "Image"
      @image = Image.find(params[:documentable_id])
      @doc.update(documentable_id: @image.id, documentable_type: "Image")
      redirect_to @image
    else
      puts "**** ERROR ****"
    end
  end

  def mark_as_current
    @doc = Doc.find(params[:id])
    doc_id = @doc.id
    if current_user.user_docs.where(image_id: @doc.documentable_id).exists?
      current_user.user_docs.where(image_id: @doc.documentable_id).destroy_all
    end
    @doc.update(current: true) unless @doc.current
    UserDoc.find_or_create_by(user_id: current_user.id, doc_id: doc_id, image_id: @doc.documentable_id)
    redirect_back_or_to @doc.documentable
  end

  # DELETE /docs/1 or /docs/1.json
  def destroy
    documentable = @doc.documentable
    # @doc.destroy!
    @doc.hide!

    respond_to do |format|
      format.html { redirect_to documentable, notice: "Doc was successfully destroyed." }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_doc
      @doc = Doc.find(params[:id])
    end

    # Only allow a list of trusted parameters through.
    def doc_params
      params.require(:doc).permit(:documentable_id, :documentable_type, :image, :raw_text, :current, :board_id, :user_id, :source_type)
    end
end
