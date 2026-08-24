module Boards
  module AdminBuilder
    # Moved to `Boards::TileArrangement` when the user-facing "Format with AI"
    # path (`Board#format_board_with_ai`) started using it too and the admin
    # namespace became a lie. Same extraction `Prompts::Aac` got out of
    # `Drafting`: the constant moves, the old name keeps resolving, no drafter
    # re-points. Zeitwerk needs the file to exist at the old path for the old
    # name to autoload — the alias can't live in the new file.
    TileArrangement = Boards::TileArrangement
  end
end
