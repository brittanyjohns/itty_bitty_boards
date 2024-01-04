json.extract! board_image, :id, :board_id, :image_id, :position, :created_at, :updated_at
json.url board_image_url(board_image, format: :json)
