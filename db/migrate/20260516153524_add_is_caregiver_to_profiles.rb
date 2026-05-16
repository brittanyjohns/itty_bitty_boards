class AddIsCaregiverToProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :profiles, :is_caregiver, :boolean, null: false, default: false
  end
end
