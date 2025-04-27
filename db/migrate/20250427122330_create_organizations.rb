class CreateOrganizations < ActiveRecord::Migration[7.1]
  def change
    create_table :organizations do |t|
      t.string :name
      t.string :slug
      t.belongs_to :admin_user, null: false, foreign_key: { to_table: :users }
      t.jsonb :settings, default: {}
      t.string :stripe_customer_id
      t.string :plan_type

      t.timestamps
    end
  end
end
