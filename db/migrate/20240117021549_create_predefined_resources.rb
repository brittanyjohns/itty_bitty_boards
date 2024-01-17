class CreatePredefinedResources < ActiveRecord::Migration[7.1]
  def change
    create_table :predefined_resources do |t|
      t.string :name
      t.string :resource_type

      t.timestamps
    end
  end
end
