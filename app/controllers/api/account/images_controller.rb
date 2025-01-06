class API::Account::ImagesController < API::Account::ApplicationController
  # protect_from_forgery with: :null_session
  respond_to :json
  before_action :authenticate_child_token!, only: %i[find_or_create]

  def find_or_create
    @current_account = current_account
    @current_user = @current_account.user

    label = params[:last_word] || params[:label]
    puts "Label: #{label}"

    is_private = params["private"] || false
    @image = Image.find_by(label: label, user_id: @current_user.id)
    @image = Image.public_img.find_by(label: label) unless @image
    @found_image = @image
    @image = Image.create(label: label, private: is_private, user_id: @current_user.id, image_prompt: params[:image_prompt], image_type: "User") unless @image || duplicate_image
    @board = Board.find_by(id: params[:board_id]) unless params[:board_id].blank?
    if @board.nil? && @image&.id
      return render json: @image.api_view(@current_user), status: :ok
    end

    if @board&.predefined && (@board&.user_id != @current_user.id)
      return render json: @image.api_view(@current_user), status: :ok unless @current_user.admin?
    end
    new_board_image = @board.add_image(@image.id) if @board

    if @found_image
      notice = "Image found!"
      @found_image.update(status: "finished") unless @found_image.finished?
      run_generate if generate_image
    else
      if @current_user.tokens > 0 && generate_image
        notice = "Generating image..."
        run_generate
      elsif !generate_image
        notice = "Image created! Remember you can always upload your own image or generate one later."
      else
        notice = "You don't have enough tokens to generate an image."
      end
    end

    if new_board_image
      render json: new_board_image.api_view
    else
      render json: @image.api_view(@current_user), notice: notice
    end
  end
end
