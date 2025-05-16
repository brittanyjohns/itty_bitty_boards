class API::MessagesController < API::ApplicationController
  before_action :set_message, only: %i[ show edit update destroy ]
  before_action :authenticate_token!

  # GET /messages or /messages.json
  def index
    @messages = current_user.messages.includes(:sender, :recipient)
    @sent_messages = @messages.sent_by_user(current_user.id)
    @received_messages = @messages.received_by_user(current_user.id)
    params[:type] ||= "inbox"
    if params[:type] == "outbox"
      @messages = @sent_messages.where(sender_deleted_at: nil)
    elsif params[:type] == "inbox"
      @messages = @received_messages.where(recipient_deleted_at: nil)
    end
    @messages = @messages.order(created_at: :desc).page(params[:page]).per(params[:page_size] || 10)

    return_data = {
      total_pages: @messages.total_pages,
      page_size: @messages.limit_value,
      data: @messages.map { |message| message.api_view(current_user) },
    }
    render json: return_data
  end

  # GET /messages/1 or /messages/1.json
  def show
    @message = Message.includes(:sender, :recipient).find(params[:id])
    unless current_user&.admin? || current_user == @message.sender || current_user == @message.recipient
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
    render json: @message.show_api_view(current_user)
  end

  # GET /messages/new
  def new
    @message = Message.new
  end

  # GET /messages/1/edit
  def edit
  end

  # POST /messages or /messages.json
  def create
    # sender_id = params[:sender_id]
    # current_user_id = current_user&.id
    # unless sender_id == current_user_id
    #   puts "Sender ID: #{sender_id}, Current User ID: #{current_user_id} - Unauthorized access"
    #   render json: { error: "Unauthorized" }, status: :unauthorized
    #   return
    # end
    puts "Params: \n\n #{params.inspect}"
    @message = Message.new(message_params)

    if @message.save
      @message.notify_recipient
      render json: @message.show_api_view(current_user), status: :created, location: @message
    else
      render json: @message.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /messages/1 or /messages/1.json
  def update
    if @message.update(message_params)
      render json: @message, status: :ok, location: @message
    else
      render json: @message.errors, status: :unprocessable_entity
    end
  end

  def mark_as_read
    @message = Message.find(params[:id])
    unless current_user&.admin? || current_user == @message.sender || current_user == @message.recipient
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
    @message.mark_as_read
    render json: @message.show_api_view(current_user)
  end

  def mark_as_unread
    @message = Message.find(params[:id])
    unless current_user&.admin? || current_user == @message.sender || current_user == @message.recipient
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
    @message.update(read_at: nil)
    render json: @message.show_api_view(current_user)
  end

  # DELETE /messages/1 or /messages/1.json
  def destroy
    # @message.destroy
    if params["hard_delete"]
      @message.destroy
    else
      @message.mark_as_deleted_by(current_user.id)
    end

    render json: { status: "ok" }
  end

  private

  def set_message
    @message = Message.find(params[:id])
  end

  def message_params
    params.require(:message).permit(:subject, :body, :sender_id, :recipient_id, :sent_at, :sender_deleted_at, :recipient_deleted_at, :read_at,
                                    attachments: [])
  end
end
