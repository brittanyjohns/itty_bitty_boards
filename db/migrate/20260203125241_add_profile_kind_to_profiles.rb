class AddProfileKindToProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :profiles, :profile_kind, :string, null: false, default: "safety"
    add_index :profiles, :profile_kind
    Profile.reset_column_information
    Profile.all.each do |profile|
      if profile.profileable_type == "ChildAccount"
        profile.update!(profile_kind: "safety")
      elsif profile.profileable_type == "User"
        profile.update!(profile_kind: "public_page")
      end
    end
  end
end
