# `images.label` is documented everywhere as the *lowercase matching key* — it
# is what every `find_by(label:)` in the app keys on — but nothing ever enforced
# that, so it doubled as display text and drifted into whatever casing the
# creating path happened to use.
#
# Splitting the two roles is what lets `label` be normalized without losing
# deliberately-cased text ("iPad", "McDonald's", "Wendy's", "PE"): the authored
# casing moves to `display_label`, and `label` becomes a pure key.
#
# The indexes are overdue independently — `label` is the hottest lookup column
# in the app and had no index at all. The functional one backs the
# case-insensitive `LOWER(label) = ?` form that `Boards::ImageResolver` and the
# new `Image.by_label` scope use.
class AddDisplayLabelToImages < ActiveRecord::Migration[8.0]
  def change
    add_column :images, :display_label, :string

    add_index :images, :label
    add_index :images, "LOWER(label)", name: "index_images_on_lower_label"
  end
end
