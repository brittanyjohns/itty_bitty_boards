# Picks one entry out of a fixed list, deterministically, for a given board.
#
# Three lists rotate a printable's listing slides so a shop page doesn't read as
# one product photographed five times — the room scene (BrandAssets::SCENES),
# the colour palette (Palette::PALETTES) and the tablet photo
# (TabletScene::SCENES). All three need the same two properties:
#
#   1. DETERMINISTIC, never random. A listing is live by the time anyone
#      re-renders it, and a random pick would re-skin a published listing on
#      every regeneration.
#   2. APPENDABLE. Adding a photo to a list must not reshuffle every board that
#      already resolved to one.
#
# All three used `SHA256(key) % list.size`, which gives (1) but not (2): the
# modulus changes the moment the list grows, so appending one scene re-skins
# essentially every printable. That is why each of those files carried a comment
# warning that its list order was load-bearing.
#
# This is rendezvous hashing (highest random weight) instead: score every entry
# against the board and take the winner. Two consequences worth having:
#
#   - ORDER STOPS MATTERING. The score depends on the entry's own slug, not its
#     position, so a list can be reordered freely. The load-bearing thing is now
#     the SLUG — renaming one re-skins the boards that had picked it, which is a
#     far easier rule to remember than "never reorder this array".
#   - Appending moves the minimum. Growing a list from n to n+m still moves
#     roughly m/(n+m) of boards, because those boards genuinely belong on the new
#     entries if the spread is to stay even — but nothing else moves, and which
#     boards move is deterministic rather than a full reshuffle.
#
# What this does NOT give you is a frozen assignment for an ALREADY-PUBLISHED
# printable. That is deliberate and currently harmless: the publish service
# refuses to publish a printable that is already on Etsy, so a live listing's
# gallery is frozen the moment its draft is created, and a re-render can only
# change what the admin previews. If that ever stops being true, the fix is to
# persist the resolved slugs on the printable and read them back here — not to
# go back to modulo.
module Boards
  module Printables
    module StablePick
      class << self
        # `entries` is any list; `slug_for` extracts the stable identity of an
        # entry (defaults to the entry itself, which suits a list of strings).
        # `salt` keeps the three lists rotating INDEPENDENTLY — without it the
        # scene and palette picks would agree forever and collapse 4 x 5 looks
        # back down to 4.
        def from(entries, salt:, board:, slug_for: :itself.to_proc)
          key = board_key(board)
          entries.max_by { |entry| score(salt, slug_for.call(entry), key) }
        end

        # The top `count` entries, best first. `from` is `top(..., 1).first`.
        #
        # Rendezvous hashing RANKS as well as maximises, so a ranked slice keeps
        # both properties above: deterministic, and appending an entry moves the
        # minimum rather than reshuffling what already resolved. That is what
        # lets the gallery ask for two DISTINCT scenes — a board photographed
        # twice in the same room reads as one screenshot pasted twice.
        #
        # A pool shorter than `count` returns what there is rather than raising:
        # a gallery that repeats a scene beats a printable that cannot render.
        def top(entries, count, salt:, board:, slug_for: :itself.to_proc)
          key = board_key(board)
          entries.sort_by { |entry| score(salt, slug_for.call(entry), key) }.reverse.first(count)
        end

        def board_key(board)
          board.try(:slug).presence || board.try(:id).to_s
        end

        private

        # Hex digests are fixed width, so comparing them as strings orders them
        # exactly as comparing the integers would — no .to_i(16) needed.
        def score(salt, slug, key)
          Digest::SHA256.hexdigest("#{salt}:#{slug}:#{key}")
        end
      end
    end
  end
end
