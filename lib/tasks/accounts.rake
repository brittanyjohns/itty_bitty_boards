namespace :accounts do
  desc "Create a number of placeholder profiles. Example: rake accounts:create_placeholder_profiles[5]"
  task :create_placeholder_profiles, [:number] => :environment do |t, args|
    number = args[:number].to_i
    if number <= 0
      puts "Please provide a positive number of placeholder accounts to create."
      return
    end
    puts "Creating #{number} placeholder profiles"
    urls = []
    number.times do
      placeholder_name = "MySpeak #{SecureRandom.hex(4)}"
      puts "Account name: #{placeholder_name}"
      slug = placeholder_name.parameterize

      profile = Profile.create!(
        username: placeholder_name,
        slug: slug,
        bio: "This is a placeholder profile. Once claimed, you can customize it.",
        intro: "Welcome to MySpeak!",
        placeholder: true,
        claimed_at: nil,
        claim_token: SecureRandom.hex(10),
      )
      puts "Created placeholder profile with username: #{profile.username} and slug #{profile.slug}"
      puts "PUBLIC URL: #{profile.public_url}"
      puts "Claim token: #{profile.claim_token}"
      puts "Claim URL: #{profile.id}"
      urls << profile.claim_url
    end
    puts "Done!"
    puts "Claim URLs:"
    urls.each { |url| puts url }
  end
end
