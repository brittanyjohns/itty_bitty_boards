# A ProfileView now records two different reveals on a MySpeak page: the gated
# emergency-info reveal (which also alerts the parent) and the gated care-
# sections reveal (which does not). Existing rows are all emergency reveals, so
# the "safety" default backfills them correctly.
class AddViewKindToProfileViews < ActiveRecord::Migration[8.0]
  def change
    add_column :profile_views, :view_kind, :string, default: "safety", null: false
  end
end
