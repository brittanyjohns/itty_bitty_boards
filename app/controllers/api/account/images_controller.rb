class API::Account::ImagesController < API::Account::ApplicationController
  # protect_from_forgery with: :null_session
  respond_to :json
  before_action :authenticate_child_token!, only: %i[find_or_create]

  def find_or_create
    @user = current_account.user
    unless @user
      return render json: { error: "User not found" }, status: :not_found
    end

    generate_image = params["generate_image"] == "1"
    duplicate_image = params["duplicate"] == "1"
    label = image_params["label"]

    is_private = image_params["private"] || false
    @image = Image.find_by(label: label, user_id: @user.id)
    @image = Image.public_img.find_by(label: label) unless @image
    @found_image = @image
    @image = Image.create(label: label, private: is_private, user_id: @user.id, image_prompt: image_params[:image_prompt], image_type: "User") unless @image || (@found_image && duplicate_image)

    @board = Board.find_by(id: image_params[:board_id]) unless image_params[:board_id].blank?
    if @board.nil? && duplicate_image && !generate_image && !@image.blank?
      return render json: @image.api_view(@user), status: :ok
    end

    if @board&.predefined && (@board&.user_id != @user.id)
      return render json: @image.api_view(@user), status: :ok unless @user.admin?
    end
    new_board_image = @board.add_image(@image.id) if @board

    if @found_image
      notice = "Image found!"
      @found_image.update(status: "finished") unless @found_image.finished?
      run_generate if generate_image
    else
      notice = "Image created!"
      run_generate if generate_image
    end

    if new_board_image
      render json: new_board_image.api_view
    else
      render json: @image.api_view(@user), notice: notice
    end
  end

  def image_params
    params.require(:image).permit(:label, :image_prompt, :display_image, :board_id,
                                  :bg_color, :text_color, :private, :image_type, :part_of_speech, :predictive_board_id,
                                  next_words: [],
                                  audio_files: [], docs: [:id, :user_id, :image, :documentable_id, :documentable_type, :processed, :_destroy])
  end
end
