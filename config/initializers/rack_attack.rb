class Rack::Attack
  # Throttle requests per IP
  throttle("req/ip", limit: 300, period: 2.minutes) do |req|
    req.ip
  end

  # Protect AI endpoints harder - example: 20 requests per minute per IP
  #   throttle("ai/ip", limit: 20, period: 1.minute) do |req|
  #     if req.path.start_with?("/api/ai")
  #       req.ip
  #     end
  #   end
end
