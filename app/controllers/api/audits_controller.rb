class API::AuditsController < API::ApplicationController
  skip_before_action :authenticate_token!
  before_action :authenticate_signed_in!, only: [:word_click, :word_events]

  def word_click
    user = current_user || current_account.user
    unless user
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    image = Image.find(params[:imageId]) if params[:imageId]
    board = Board.includes(:user).find(params[:boardId]) if params[:boardId]
    unless image
      image = current_account.images.find_by(label: params[:word]) if current_account
      image = current_user.images.find_by(label: params[:word]) if current_user
    end

    board_image_id = params[:boardImageId]
    board_image = BoardImage.find_by(id: board_image_id.to_i) if board_image_id
    unless board_image
      board_image = BoardImage.find_by(board_id: params[:boardId], image_id: params[:imageId]) if params[:boardId] && params[:imageId]
    end
    screen_size = params[:screenSize]
    layout = params[:layout]
    if layout.blank? && board_image
      layout = board_image.layout || {}
    end
    layout_for_screen_size = layout[screen_size] || {}

    x_position = params[:xPosition] || layout_for_screen_size["x"]
    y_position = params[:yPosition] || layout_for_screen_size["y"]
    width = params[:width] || layout_for_screen_size["w"]
    height = params[:height] || layout_for_screen_size["h"]
    number_of_columns = board&.columns_for_screen_size(screen_size)
    number_of_rows = board&.rows_for_screen_size(screen_size)
    word_event_data = {
      screen_size: screen_size,
      layout: layout_for_screen_size,
      x_position: x_position,
      y_position: y_position,
      width: width,
      height: height,
      number_of_columns: number_of_columns,
      number_of_rows: number_of_rows,
    }

    payload = {
      word: params[:word],
      previous_word: params[:previousWord],
      image_id: params[:imageId],
      timestamp: params[:timestamp],
      image_id: image&.id,
      user_id: user.id,
      board_id: params[:boardId],
      team_id: user.current_team_id, # current_team_id is not being set
      child_account_id: current_account&.id,
      board_image_id: board_image&.id,
      data: word_event_data,
    }

    WordEvent.create(payload)
    render json: { message: "Word click recorded" }
  end

  def word_events
    if params[:user_id]
      @user = User.includes(:word_events).find(params[:user_id])
      @word_events = @user.word_events.limit(500)
      # @word_events = WordEvent.where(user_id: params[:user_id]).limit(200)
    elsif params[:account_id]
      @word_events = WordEvent.includes(:image, :board, :child_account).where(child_account_id: params[:account_id]).order(timestamp: :desc).limit(500)
    else
      @word_events = WordEvent.includes(:image, :board, :child_account).order(timestamp: :desc).limit(500)
    end
    render json: @word_events.order(created_at: :desc).map { |event|
      event.api_view(current_user || current_account.user)
    }
  end

  def public_word_click
    image_id = params[:imageId]
    board_id = params[:boardId]
    image = Image.find(params[:imageId]) if params[:imageId]
    board = Board.includes(:user).find(params[:boardId]) if params[:boardId]

    profileId = params[:profileId]
    comm_account = nil
    if profileId
      profile = Profile.find_by(id: profileId.to_i)
      unless profile.nil?
        comm_account = profile.profileable
        if comm_account.nil?
          Rails.logger.error "No Communicator Account found for Profile ID: #{profileId}"
        end
      end
    else
      Rails.logger.error "No Profile ID provided."
      profile = nil
    end
    request_ip = request.remote_ip
    request_ip = "8.8.8.8" if request_ip == "::1"
    location_data = get_ip_location(request_ip)
    request_data = {
      path: request.fullpath,
      params: params.to_unsafe_h,
      ip: request_ip,
      location: {
        city: location_data["city"],
        region: location_data["region"],
        country: location_data["country_name"],
        latitude: location_data["latitude"],
        longitude: location_data["longitude"],
      },
      user_agent: request.user_agent,
      referer: request.referer,
    }
    board_image = nil
    if params[:boardImageId]
      board_image = BoardImage.find_by(id: params[:boardImageId].to_i)
    end
    unless board_image
      board_image = BoardImage.find_by(board_id: board_id.to_i, image_id: image_id.to_i) if board_id && image_id
    end
    screen_size = params[:screenSize]
    layout = params[:layout] || board_image&.layout || {}
    layout_for_screen_size = layout[screen_size] || {}

    x_position = params[:xPosition] || layout_for_screen_size["x"]
    y_position = params[:yPosition] || layout_for_screen_size["y"]
    width = params[:width] || layout_for_screen_size["w"]
    height = params[:height] || layout_for_screen_size["h"]
    number_of_columns = board&.columns_for_screen_size(screen_size)
    number_of_rows = board&.rows_for_screen_size(screen_size)

    word_event_data = {
      screen_size: screen_size,
      layout: layout_for_screen_size,
      x_position: x_position,
      y_position: y_position,
      width: width,
      height: height,
      number_of_columns: number_of_columns,
      number_of_rows: number_of_rows,
    }
    data = request_data.merge(word_event_data)

    payload = {
      word: params[:word],
      previous_word: params[:previousWord],
      image_id: params[:imageId],
      timestamp: params[:timestamp],
      image_id: image&.id,
      user_id: board&.user&.id,
      board_id: params[:boardId],
      board_group_id: params[:boardGroupId],
      board_image_id: board_image&.id,
      child_account_id: comm_account&.id,
      vendor_id: params[:vendorId],
      profile_id: profile&.id,
      data: data,
    }
    word_event = WordEvent.create(payload)
    render json: { message: "Word click recorded", word_event: word_event&.api_view }
  end

  def get_ip_location(ip = request.remote_ip)
    ip = "8.8.8.8" if ip == "::1"

    Rails.cache.fetch("ip-location-#{ip}", expires_in: 10.minutes) do
      uri = URI("http://ip-api.com/json/#{ip}")
      response = Net::HTTP.get_response(uri)
      JSON.parse(response.body)
    end
  rescue => e
    Rails.logger.error("IP location fetch failed: #{e.message}")
    { "error" => "Unable to get location" }
  end
end
