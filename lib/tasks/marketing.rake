namespace :marketing do
  # The AAC Classroom Kit's safety + device tags reuse the existing
  # Profile-driven generators (Communicators::GenerateSafetyIdCard /
  # GenerateDeviceTag), which need a real safety Profile. This seeds ONE
  # admin-owned, clearly-generic sample communicator + safety profile so the kit
  # renders realistic (filled) sample tags without touching any real child's
  # data. Idempotent — safe to re-run.
  #
  #   bin/rails marketing:seed_kit_sample_profile
  #
  # Prints the profile id + slug for the printables marketing-kit script to
  # fetch tags from (GET /api/internal/profiles/:id with a qr_target_url).
  desc "Seed the generic AAC Classroom Kit sample safety profile (idempotent)"
  task seed_kit_sample_profile: :environment do
    admin = User.find(User::DEFAULT_ADMIN_ID)

    child = ChildAccount.find_or_initialize_by(username: "speakanyway-sample")
    child.user = admin
    child.name = "SpeakAnyWay Sample" if child.name.blank?
    child.status = ChildAccount::ACTIVE if child.status.blank?
    child.save!

    profile = child.profile || child.create_profile!

    sample_settings = {
      "device_notes" => "This device is my voice. Please use it to help me communicate and access important information in any situation.",
      "emergency_notes" => "Please stay calm, speak to me directly, and let me use my device to respond.",
      "allergies" => "Sample: none listed",
      "medical_conditions" => "Sample: none listed",
      "medications" => "Sample: none listed",
      "ice_contact_1" => {
        "name" => "Sample Caregiver",
        "phone" => "(555) 123-4567",
        "relationship" => "Parent / Guardian",
      },
    }

    profile.settings = (profile.settings || {}).merge(sample_settings)
    profile.save!

    puts "AAC Classroom Kit sample profile ready:"
    puts "  child_account_id: #{child.id}"
    puts "  profile_id:       #{profile.id}"
    puts "  profile_slug:     #{profile.slug}"
  end
end
