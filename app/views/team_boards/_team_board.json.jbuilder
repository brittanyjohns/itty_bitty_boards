json.extract! team_board, :id, :board_id, :team_id, :allow_edit, :created_at, :updated_at
json.url team_board_url(team_board, format: :json)
