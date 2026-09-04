# Serves the curated quick-add word packs (Boards::WordPacks) for the frontend's
# Add-tiles modal, together with the art each word can already be drawn with.
#
# STRICTLY READ-ONLY, and that is the whole design constraint: this fires on
# every open of the modal, so it may not create Image rows, spend credits, or
# reach OpenAI. Art lookup goes through Boards::ImageResolver.arted_all_for, the
# read-only batch form — never `resolve_all`, which creates a blank Image for a
# label with no match anywhere.
class API::WordPacksController < API::ApplicationController
  def index
    board = find_board
    packs = Boards::WordPacks.for_board(board)

    arted = Boards::ImageResolver.arted_all_for(
      packs.flat_map { |pack| pack[:words] }, owner: current_user
    )
    on_board = Boards::WordPacks.placed_keys(board)

    render json: {
             packs: packs.map { |pack| pack_view(pack, arted, on_board) },
           }, status: :ok
  end

  private

  # Ownership-scoped, and a board the caller can't reach is treated as "no
  # board" rather than 404'd: the packs are a static catalog, so the board only
  # decides which ones are offered and which words are already placed.
  def find_board
    return nil if params[:board_id].blank?

    Board.find_by(id: params[:board_id], user_id: current_user.id)
  end

  def pack_view(pack, arted, on_board)
    {
      key: pack[:key],
      name: pack[:name],
      description: pack[:description],
      words: pack[:words].map { |word| word_view(word, arted, on_board) },
    }
  end

  def word_view(word, arted, on_board)
    key = Boards::WordPacks.normalize_key(word)
    image = arted[key]
    {
      label: word,
      # nil means "no picture in the library yet" — the tile still lands, it
      # just lands blank. The client says so rather than letting it surprise.
      src: thumbnail_for(image),
      on_board: on_board.include?(key),
    }
  end

  # `src_url` FIRST because it is a plain column: this endpoint asks about every
  # word of every pack, and `display_image_url` is two queries an image
  # (`user_docs`, then `docs.for_user`) — ~200 on a single modal open.
  # `update_src_url` is a `before_save` guarded on the column being blank, so a
  # row with art that has never been re-saved can still have none; those few pay
  # the real lookup rather than being reported as picture-less. The trade is
  # that a viewer's own per-doc pick (`UserDoc`) doesn't show in the PREVIEW —
  # `best_arted_all` already prefers their own image row, and the tile itself
  # resolves normally once added.
  def thumbnail_for(image)
    return nil unless image

    image.src_url.presence || image.display_image_url(current_user)
  end
end
