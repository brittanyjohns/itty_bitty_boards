json.extract! board, :id, :user_id, :name, :parent_id, :parent_type, :description, :created_at, :updated_at
json.url board_url(board, format: :json)
