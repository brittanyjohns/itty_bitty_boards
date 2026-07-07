class API::MessagesController < API::ApplicationController
  before_action :set_message, only: %i[ show edit update destroy mark_as_read mark_as_unread ]
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
    @message = Message.new(message_params)
    # Ownership is server-decided: the sender is always the authenticated user
    # (a client must not be able to forge a message "from" someone else), and
    # the recipient is taken explicitly from the request rather than
    # mass-assigned. Neither rides the permit list — see #message_params.
    @message.sender_id = current_user.id
    @message.recipient_id = params.dig(:message, :recipient_id)

    if @message.save
      @message.notify_recipient
      render json: @message.show_api_view(current_user), status: :created
    else
      render json: @message.errors, status: :unprocessable_content
    end
  end

  # PATCH/PUT /messages/1 or /messages/1.json
  def update
    if @message.update(message_params)
      render json: @message, status: :ok
    else
      render json: @message.errors, status: :unprocessable_content
    end
  end

  def mark_as_read
    @message.mark_as_read
    render json: @message.show_api_view(current_user)
  end

  def mark_as_unread
    @message.update(read_at: nil)
    render json: @message.show_api_view(current_user)
  end

  # DELETE /messages/1 or /messages/1.json
  def destroy
    # @message.destroy
    @remaining_messages = []
    if params["hard_delete"]
      @message.destroy
    else
      puts "Recipient ID: #{@message.recipient_id} - Sender ID: #{@message.sender_id}"
      puts "Current User ID: #{current_user.id}"
      if @message.sender_id == current_user.id
        @remaining_messages = @message.mark_as_deleted_by(current_user.id, "sender")
      elsif @message.recipient_id == current_user.id
        @remaining_messages = @message.mark_as_deleted_by(current_user.id, "recipient")
      else
        render json: { error: "Unauthorized" }, status: :unauthorized
        return
      end
    end

    render json: @remaining_messages.map { |message| message.api_view(current_user) }, status: :ok
  end

  private

  def set_message
    @message = Message.where("sender_id = :uid OR recipient_id = :uid", uid: current_user.id).find(params[:id])
  end

  def message_params
    # :sender_id / :recipient_id are intentionally NOT permitted — ownership is
    # assigned server-side in #create (sender = current_user, recipient taken
    # explicitly) so a client can't forge or reassign them (mass-assignment, #27).
    params.require(:message).permit(:subject, :body, :sent_at, :sender_deleted_at, :recipient_deleted_at, :read_at,
                                    attachments: [])
  end
end
