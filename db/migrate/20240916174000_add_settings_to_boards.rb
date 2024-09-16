class AddSettingsToBoards < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :settings, :jsonb, default: {}
  end
end
