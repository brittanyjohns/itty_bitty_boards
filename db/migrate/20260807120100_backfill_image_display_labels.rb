# Backfill for the label/display_label split.
#
# Three passes, and the order between them is load-bearing:
#
# 1. Every row's authored casing moves verbatim into `display_label`. Nothing
#    renders differently after this pass — it only stops the information from
#    being destroyed by pass 3.
#
# 2. Folder tiles that picked up accidental Title Case from the seed path
#    ("Animals", "Play", "Time") get lowercased. The signal for "accidental" is
#    that the *same word already exists lowercase* elsewhere in the library —
#    which is exactly the collision that made one board render "Higher" next to
#    "swing". This must run before pass 3, because after pass 3 every row has a
#    lowercase twin and the test stops meaning anything.
#
#    Deliberately narrow: `image_type = 'category'` and a single plain
#    Title-Cased word. That covers the ~21 real folder tiles and cannot touch
#    the imported source-collection names ("CommuniKate weather",
#    "Core 24 - Small Words", "Home - Sequoia 15 - Calloway") or any acronym or
#    brand ("PE", "iPad", "McDonald's"), none of which are single plain words.
#
# 3. `label` becomes the lowercase, stripped matching key the whole app already
#    assumed it was.
#
# Raw SQL rather than find_each: this touches every image row, and Image's
# before_save chain (categorization, color defaults, board-image fan-out) has no
# business firing for a casing correction.
class BackfillImageDisplayLabels < ActiveRecord::Migration[8.0]
  def up
    say_with_time "Copying authored casing into images.display_label" do
      execute(<<~SQL)
        UPDATE images
           SET display_label = label
         WHERE display_label IS NULL
      SQL
    end

    say_with_time "Lowercasing accidentally Title-Cased folder tiles" do
      execute(<<~SQL)
        UPDATE images
           SET display_label = LOWER(display_label)
         WHERE image_type = 'category'
           AND display_label ~ '^[A-Z][a-z]+$'
           AND EXISTS (
                 SELECT 1
                   FROM images AS twin
                  WHERE twin.label = LOWER(images.display_label)
                    AND twin.id <> images.id
               )
      SQL
    end

    say_with_time "Normalizing images.label to the lowercase matching key" do
      execute(<<~SQL)
        UPDATE images
           SET label = LOWER(BTRIM(label))
         WHERE label IS DISTINCT FROM LOWER(BTRIM(label))
      SQL
    end
  end

  # Irreversible on purpose. `label`'s pre-migration casing is recoverable from
  # `display_label` for most rows, but not for the folder tiles pass 2 cleaned —
  # and restoring the rest would re-break every case-sensitive lookup this
  # migration exists to fix. Rolling back means dropping the column (the
  # preceding migration), not resurrecting the old casing.
  def down
    say "No-op: label normalization is not reversible."
  end
end
