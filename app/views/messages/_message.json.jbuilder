json.extract! message, :id, :subject, :body, :user_id, :created_at, :updated_at
json.url message_url(message, format: :json)
