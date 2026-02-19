class AddAllowDiscoveryToPages < ActiveRecord::Migration[7.1]
  def change
    add_column :profiles, :allow_discovery, :boolean, default: false, null: false

    # Set allow_discovery to true for existing public pages
    reversible do |dir|
      dir.up do
        execute <<-SQL.squish
          UPDATE profiles
          SET allow_discovery = true
          WHERE profile_kind = 'public_page'
        SQL
      end
    end
  end
end
