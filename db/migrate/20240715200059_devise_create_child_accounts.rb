# frozen_string_literal: true

class DeviseCreateChildAccounts < ActiveRecord::Migration[7.1]
  def change
    create_table :child_accounts do |t|
      ## Database authenticatable
      t.string :username, null: false, default: ""
      t.string :name, default: ""
      t.string :encrypted_password, null: false, default: ""

      ## Recoverable
      t.string :reset_password_token
      t.datetime :reset_password_sent_at

      ## Rememberable
      t.datetime :remember_created_at

      ## Trackable
      t.integer :sign_in_count, default: 0, null: false
      t.datetime :current_sign_in_at
      t.datetime :last_sign_in_at
      t.string :current_sign_in_ip
      t.string :last_sign_in_ip

      t.references :user, null: false, foreign_key: true
      t.string :authentication_token
      t.jsonb :settings, default: {}

      t.timestamps null: false
    end

    add_index :child_accounts, :username, unique: true
    add_index :child_accounts, :reset_password_token, unique: true
    add_index :child_accounts, :authentication_token, unique: true
    ChildAccount.find_each.map(&:regenerate_authentication_token)
    add_column :users, :child_lookup_key, :string
    add_index :users, :child_lookup_key, unique: true
  end
end
