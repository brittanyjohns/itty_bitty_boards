class AddMarginToBoards < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :margin_settings, :jsonb, default: {}
  end
end
