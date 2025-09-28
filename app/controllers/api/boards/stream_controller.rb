# app/controllers/api/boards/stream_controller.rb
class API::Boards::StreamController < API::ApplicationController
  include ActionController::Live

  def show
    authorize_communicator_account! params[:communicator_account_account_id]
    response.headers["Content-Type"] = "text/event-stream"
    sse = SSE.new(response.stream, retry: 5000)

    # Basic notifier: listen on Redis pubsub or use a simple loop checking updated_at
    Redis.new(url: ENV["REDIS_URL"]).subscribe("boards:communicator_account:#{params[:communicator_account_account_id]}") do |on|
      on.message do |_chan, message|
        sse.write(message, event: "board.updated")
      end
    end
  ensure
    sse.close rescue nil
  end
end
