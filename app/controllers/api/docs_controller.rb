class API::DocsController < API::ApplicationController
  before_action :authenticate_token!

  before_action :set_doc, only: %i[ show edit update destroy ]

  # GET /docs or /docs.json
  def index
    set_scoped_docs
    # @docs = Doc.image_docs.order(created_at: :desc).page params[:page]
    search_param = params[:query]&.strip
    puts "search_param: #{search_param}"
    if params[:query].present?
      @docs = @docs.where("processed ILIKE ?", "%#{search_param}%").order(processed: :asc).page params[:page]
    else
      @docs = @docs.order(processed: :asc).page params[:page]
    end
    if turbo_frame_request?
      render partial: "docs", locals: { docs: @docs }
    else
      render :index
    end
  end

  def find_or_create_image
    @doc = Doc.unscoped.find(params[:id])
    @label = params[:label]
    puts "Processing #{@label} for doc id #{@doc.id}"

    @image = Image.searchable_images_for(current_user).find_or_create_by(label: @label)
    @doc.update!(documentable_id: @image.id, documentable_type: "Image", deleted_at: nil)
    redirect_back_or_to @image
  end

  def deleted
    @docs = Doc.hidden.order(created_at: :desc).page params[:page]
    search_param = params[:query]&.strip
    if params[:query].present?
      @docs = @docs.where("processed ILIKE ?", "%#{search_param}%").order(processed: :asc).page params[:page]
    else
      @docs = @docs.order(processed: :asc).page params[:page]
    end
    if turbo_frame_request?
      render partial: "docs", locals: { docs: @docs }
    else
      render :deleted
    end
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
      @old_fav_docs = current_user.user_docs.includes(:doc).where(image_id: @doc.documentable_id)
      @old_fav_docs.each do |old_fav_doc|
        old_fav_doc.doc.update(current: false) if old_fav_doc.user_id == current_user.id
      end
      @old_fav_docs.destroy_all
    end
    @doc.reload
    user_doc = UserDoc.create!(user_id: current_user.id, doc_id: doc_id, image_id: @doc.documentable_id)
    did_update = @doc.update(current: true)
    if did_update
      puts "Doc updated successfully"
    else
      puts "Doc did not update"
    end
    @current_doc = @doc
    @image = @doc.documentable
    @user = @image.user
    if @user.nil? && current_user.admin?
      @user = current_user
      @image.update!(src_url: @current_doc.display_url)
      board_imgs = Board_images.where(image_id: @image.id, user_id: [nil, User::DEFAULT_ADMIN_ID]).update_all(display_image_url: @current_doc.display_url)
    end
    if @user.id == current_user.id
      @image.update!(src_url: @current_doc.display_url)
      board_imgs = @user.board_images.where(image_id: @image.id).update_all(display_image_url: @current_doc.display_url)
    end

    @image_docs = @image.docs.for_user(current_user).excluding(@doc).order(created_at: :desc).to_a
    # @doc_with_image = { doc: @doc, image: @image, current_doc: @doc, image_docs: @image_docs }
    @image_with_display_doc = {
      id: @image.id,
      label: @image.label.upcase,
      image_prompt: @image.image_prompt,
      image_type: @image.image_type,
      bg_color: @image.bg_class,
      text_color: @image.text_color,
      display_doc: {
        id: @current_doc&.id,
        label: @image&.label,
        user_id: @current_doc&.user_id,
        src: @current_doc&.display_url,
        is_current: true,
        deleted_at: @current_doc&.deleted_at,
      },
      private: @image.private,
      user_id: @image.user_id,
      next_words: @image.next_words,
      no_next: @image.no_next,
      src: @image.display_image_url(current_user),
      docs: @image_docs.map do |doc|
        {
          id: doc.id,
          label: @image.label,
          user_id: doc.user_id,
          src: doc.display_url,
          is_current: doc.id == @current_doc_id,
        }
      end,
    }
    render json: @image_with_display_doc
  end

  # DELETE /docs/1 or /docs/1.json
  def destroy
    documentable = @doc.documentable
    if params[:hard_delete]
      @doc.destroy
    else
      @doc.hide
    end

    respond_to do |format|
      format.html { redirect_back_or_to documentable, notice: "Doc was successfully destroyed." }
      format.json { head :no_content }
      format.turbo_stream { render turbo_stream: turbo_stream.remove(@doc) }
    end
  end

  private

  def set_scoped_docs
    case params[:scope]
    when "symbols"
      @docs = Doc.symbols.order(created_at: :desc).page params[:page]
    when "ai_generated"
      @docs = Doc.ai_generated.order(created_at: :desc).page params[:page]
    else
      @docs = Doc.all.order(created_at: :desc).page params[:page]
    end
  end

  # Use callbacks to share common setup or constraints between actions.
  def set_doc
    @doc = Doc.unscoped.find(params[:id])
  end

  # Only allow a list of trusted parameters through.
  def doc_params
    params.require(:doc).permit(:documentable_id, :documentable_type, :image, :raw, :current, :board_id, :user_id, :source_type)
  end
end
