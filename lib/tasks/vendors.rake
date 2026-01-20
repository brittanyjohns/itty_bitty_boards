namespace :vendors do
  desc "Create New Vendor Example: rake vendors:create_new_vendor[1, 'My Business', 'info@speakanyway.com', 'https://www.speakanyway.com']"
  task :create_new_vendor, [:user_id, :business_name, :business_email, :website] => :environment do |t, args|
    business_name = args[:business_name]
    business_email = args[:business_email]
    website = args[:website]
    user_id = args[:user_id]
    user = User.find_by(id: user_id) if user_id.present?
    if user_id.present? && user.nil?
      puts "User with ID #{user_id} not found"
      return
    end
    if business_name.blank? || business_email.blank?
      puts "Business name and email are required"
      return
    end
    vendor = Vendor.create_from_email(user.email, business_name, business_email, website)
    if vendor
      puts "Vendor created successfully: #{vendor.business_name} (ID: #{vendor.id})"
      puts "Profile created with username: #{vendor.profile.username}" if vendor.profile
    else
      puts "Failed to create vendor"
    end
  end
end
