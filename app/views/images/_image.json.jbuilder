json.extract! image, :id, :label, :image_prompt, :private, :user_id, :created_at, :updated_at
json.url image_url(image, format: :json)
