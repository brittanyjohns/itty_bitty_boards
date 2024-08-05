class API::BoardsController < API::ApplicationController
  # protect_from_forgery with: :null_session
  respond_to :json

  # before_action :authenticate_user!
  skip_before_action :authenticate_token!, only: %i[ predictive_index first_predictive_board predictive_images ]

  before_action :set_board, only: %i[ associate_image remove_image destroy ]
  # layout "fullscreen", only: [:fullscreen]
  # layout "locked", only: [:locked]

  # GET /boards or /boards.json
  def index
    if params[:query].present?
      @query = params[:query]
      @boards = boards_for_user.user_made_with_scenarios.where("name ILIKE ?", "%#{params[:query]}%").order(name: :desc)
      @predefined_boards = Board.predefined.where("name ILIKE ?", "%#{params[:query]}%").order(name: :desc)
    else
      @boards = boards_for_user.user_made_with_scenarios.order(created_at: :desc)
      @predefined_boards = Board.predefined.order(created_at: :desc)
    end

    render json: { boards: @boards.map { |b| b.api_view(current_user) },
                   predefined_boards: @predefined_boards }
  end

  def user_boards
    # @boards = boards_for_user.user_made_with_scenarios_and_menus.order(created_at: :desc)
    @boards = boards_for_user.user_made_with_scenarios.order(created_at: :desc)

    render json: { boards: @boards }
  end

  def predictive_index
    @boards = Board.with_artifacts.predictive
    @predictive_boards = @boards.map do |board|
      {
        id: board.id,
        name: board.name,
        description: board.description,
        parent_type: board.parent_type,
        predefined: board.predefined,
        number_of_columns: board.number_of_columns,
        images: board.board_images.map do |board_image|
          {
            id: board_image.image.id,
            label: board_image.image.label,
            image_prompt: board_image.image.image_prompt,
            bg_color: board_image.image.bg_class,
            text_color: board_image.image.text_color,
            next_words: board_image.next_words,
            position: board_image.position,
            src: board_image.image.display_image_url(current_user),
            audio: board_image.image.default_audio_url,
          }
        end,
      }
    end
    render json: @predictive_boards
  end

  def first_predictive_board
    @board = Board.predictive_default
    if @board
      puts "Predictive board found"
    else
      puts "No predictive board found"
      @board = Board.create_predictive_default
      puts "Predictive board created"
    end
    @board_with_images = @board.board_images.map do |board_image|
      image = board_image.image # temp fix
      {
        id: image.id,
        label: image.label,
        bg_color: image.bg_class,
        next_words: board_image.next_words,
        src: image.display_image_url(current_user),
        audio: image.default_audio_url,
      }
    end
    render json: @board_with_images
  end

  def predictive_images
    @image = Image.with_artifacts.find(params[:id])
    @next_images = @image.next_images.map do |ni|
      {
        id: ni.id,
        label: ni.label,
        bg_color: ni.bg_class,
        src: ni.display_image_url(current_user),
        audio: ni.default_audio_url,
      }
    end
    render json: @next_images
  end

  def show
    board = Board.with_artifacts.find(params[:id])
    if board.print_grid_layout.values.any?(&:empty?)
      board.calucate_grid_layout
      board.save!
    end
    @board_with_images = board.api_view_with_images(current_user)
    user_permissions = {
      can_edit: (board.user == current_user || current_user.admin?),
      can_delete: (board.user == current_user || current_user.admin?),
    }
    render json: @board_with_images.merge(user_permissions)
  end

  def save_layout
    puts "API::BoardsController#reorder_images: #{params.inspect}"
    board = Board.with_artifacts.find(params[:id])
    layout = params[:layout]
    layout.each_with_index do |layout_item, index|
      puts "layout_item[#{index}]: #{layout_item.inspect}"
      image_id = layout_item["i"]
      board_image = board.board_images.find_by(image_id: image_id)
      # board_image = board.board_images.find(layout_item["i"])
      board_image.layout = layout_item
      board_image.save!
    end
    board.reload
    render json: board.api_view_with_images(current_user)
  end

  def remaining_images
    board = Board.with_artifacts.find(params[:id])
    # board = Board.find(params[:id])
    current_page = params[:page] || 1
    puts "board: #{board.inspect}"
    if params[:query].present? && params[:query] != "null"
      @query = params[:query]
      @images = Image.non_menu_images.with_artifacts.where("label ILIKE ?", "%#{params[:query]}%").order(label: :asc).page(current_page)
    else
      @images = Image.non_menu_images.with_artifacts.all.order(label: :asc).page(current_page).page(current_page)
    end
    @images = @images.excluding(board.images)
    @remaining_images = @images.map do |image|
      {
        id: image.id,
        label: image.label,
        image_prompt: image.image_prompt,
        bg_color: image.bg_class,
        text_color: image.text_color,
        src: image.display_image_url(current_user),
      # audio: image.default_audio_url,
      }
    end

    render json: @remaining_images
  end

  def rearrange_images
    @board = Board.find(params[:id])
    puts "API::BoardsController#rearrange_images: #{params.inspect}"

    # ActiveRecord::Base.logger.silence do
    @board.rearrange_images(params[:layout])
    # if params[:layout].present?
    #   layout = params[:layout]
    #   board.update_grid_layout(layout)
    # else
    #   board.calucate_grid_layout
    # end
    @board.save!
    # end
    render json: @board.api_view_with_images(current_user)
  end

  # POST /boards or /boards.json
  def create
    puts "API::BoardsController#create: #{board_params.inspect}"
    @board = Board.new(board_params)
    @board.user = current_user
    @board.parent_id = user_signed_in? ? current_user.id : params[:parent_id]
    @board.parent_type = params[:parent_type] || "User"

    respond_to do |format|
      if @board.save
        format.json { render json: @board, status: :created }
        format.turbo_stream
      else
        format.json { render json: @board.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /boards/1 or /boards/1.json
  def update
    ActiveRecord::Base.logger.silence do
      @board = Board.with_artifacts.find(params[:id])
    end
    @board.number_of_columns = board_params["number_of_columns"].to_i
    @board.voice = params["voice"]
    @board.name = params["name"]
    @board.description = params["description"]
    @board.display_image_url = params["display_image_url"]
    @board.predefined = params["predefined"]
    puts "API::BoardsController#update: #{params.inspect}"
    puts @board.voice ? "Voice: #{@board.voice}" : "No voice"
    respond_to do |format|
      if @board.save
        format.json { render json: @board.api_view_with_images(current_user), status: :ok }
      else
        format.json { render json: @board.errors, status: :unprocessable_entity }
      end
    end
  end

  def add_image
    @board = Board.with_artifacts.find(params[:id])
    @found_image = Image.find_by(label: image_params[:label], user_id: current_user.id, private: true)
    @found_image ||= Image.find_by(label: image_params[:label])
    if @found_image
      @image = @found_image
      img_saved = true
    else
      @image = Image.new
      @image.user = current_user
      @image.private = true
      @image.label = image_params[:label]
      img_saved = @image.save!
    end

    if (image_params[:docs].present?)
      doc = @image.docs.new(image_params[:docs])
      doc.user = current_user
      doc.processed = true
      doc.save
    end
    if img_saved
      @board.add_image(@image.id) if @board

      @board_with_images = @board.api_view_with_images(current_user)
      @board.calucate_grid_layout
      render json: @board_with_images
    else
      render json: img_saved.errors, status: :unprocessable_entity
    end
  end

  def create_from_next_words
    @board = Board.new(board_params)
    @board.user = current_user
    @board.parent_id = user_signed_in? ? current_user.id : params[:parent_id]
    @board.parent_type = params[:parent_type] || "User"
    @board.save!
    @board.create_images_from_next_words(params[:next_words])
    render json: @board.api_view_with_images(current_user)
  end

  def associate_image
    puts "API::BoardsController#associate_image: #{params.inspect}"
    image = Image.find(params[:image_id])
    if @board.images.include?(image)
      render json: { error: "Image already associated with board" }, status: :unprocessable_entity
      return
    end
    if @board.predefined && !current_user.admin?
      render json: { error: "Cannot add images to predefined boards" }, status: :unprocessable_entity
      return
    end

    new_board_image = @board.board_images.new(image_id: image.id, position: @board.board_images.count)
    if new_board_image.save
      next_grid_cell = @board.next_grid_cell
      new_layout = { i: new_board_image.id, x: next_grid_cell[:x], y: next_grid_cell[:y], w: 1, h: 1 }
      # new_layout = { i: new_board_image.id, x: 0, y: 0, w: 1, h: 1}
      new_board_image.update!(layout: new_layout)
    else
      render json: { error: "Error adding image to board: #{new_board_image.errors.full_messages.join(", ")}" }, status: :unprocessable_entity
      return
    end
    @board.calucate_grid_layout
    render json: { board: @board, new_board_image: new_board_image, label: image.label }
  end

  def remove_image
    if @board.predefined && !current_user.admin?
      render json: { error: "Cannot remove images from predefined boards" }, status: :unprocessable_entity
      return
    end
    @image = Image.find(params[:image_id])
    @board.images.delete(@image)
    @board.reload
    render json: @board, status: :ok
  end

  # # DELETE /boards/1 or /boards/1.json
  def destroy
    @board.destroy!

    respond_to do |format|
      format.json { head :no_content }
    end
  end

  def add_to_team
    @team = Team.find(params[:team_id])
    @board = Board.find(params[:id])
    @team.boards << @board
    render json: @team.show_api_view
  end

  def clone
    @board = Board.with_artifacts.find(params[:id])
    @new_board = Board.new
    @new_board.description = @board.description
    @new_board.user = current_user
    @new_board.parent_id = current_user.id
    @new_board.parent_type = "User"
    @new_board.predefined = false
    @new_board.name = "Copy of " + @board.name
    @board.images.each do |image|
      @new_board.add_image(image.id)
    end
    @new_board.save!
    render json: @new_board.api_view_with_images(current_user)
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_board
    @board = Board.with_artifacts.find(params[:id])
  end

  def boards_for_user
    current_user.boards.with_artifacts
  end

  def image_params
    params.require(:image).permit(:label, :image_prompt, :display_image, audio_files: [], docs: [:id, :user_id, :image, :documentable_id, :documentable_type, :processed, :_destroy])
  end

  # Only allow a list of trusted parameters through.
  def board_params
    params.require(:board).permit(:user_id,
                                  :name,
                                  :parent_id,
                                  :parent_type,
                                  :description,
                                  :predefined,
                                  :number_of_columns,
                                  :next_words,
                                  :images,
                                  :layout,
                                  :image_ids,
                                  :image_id,
                                  :query,
                                  :page,
                                  :display_image_url)
  end
end
