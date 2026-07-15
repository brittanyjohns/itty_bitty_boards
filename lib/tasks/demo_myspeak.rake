# lib/tasks/demo_myspeak.rake
# Seed 3 fictional demo communicators as MySpeak pages (AAC profile + gated
# safety data). Idempotent / re-runnable. All data is fictional: phone numbers
# use the 555-01xx fiction range; emails use the reserved @example.com domain.
#
#   bundle exec rake demo:myspeak_communicators              # dedicated demo owner
#   bundle exec rake demo:myspeak_communicators USER_ID=740  # attach to a specific user
namespace :demo do
  DEMO_OWNER_EMAIL = "demo-myspeak@speakanyway.dev".freeze

  DEMO_COMMUNICATORS = [
    {
      name: "Mateo Rivera",
      username: "mateo-rivera",
      details: { "aac_level" => "emerging", "vocab_type" => "core", "age_band" => "4-6", "glp_stage" => 1 },
      settings: {
        "pronouns" => "he/him",
        "headline" => "Learning new words every day 🌱",
        "device_notes" => "iPad in a red case, volume all the way up. Mateo taps with his whole hand, so give him a second after each press. If the app freezes, close and reopen it — his boards save automatically.",
        "role_badges" => ["Communicator"],
        "show_email" => false,
        "allergies" => "Peanuts and tree nuts — severe. Carries an EpiPen in his backpack's front pocket.",
        "medical_conditions" => "Autism; mild asthma.",
        "medications" => "Albuterol (rescue inhaler) as needed for wheezing.",
        "emergency_notes" => "Mateo is a runner — he may bolt toward water, roads, or exits when overwhelmed, so keep a hand nearby in open spaces. He covers his ears and may drop to the floor around loud noises (fire alarms, hand dryers). Deep pressure (a firm hug) and his \"Twinkle Twinkle\" song help him settle. He uses mostly single words on his device plus pointing and gestures — give him time, he understands more than he can say.",
        "ice_contact_1" => { "name" => "Daniela Rivera", "phone" => "(216) 555-0142", "relationship" => "Mother" },
        "ice_contact_2" => { "name" => "Marco Rivera", "phone" => "(216) 555-0143", "relationship" => "Father" },
        "ice_contact_3" => { "name" => "Rosa Delgado", "phone" => "(216) 555-0144", "relationship" => "Grandmother" }
      }
    },
    {
      name: "Ava Chen",
      username: "ava-chen",
      details: { "aac_level" => "proficient", "vocab_type" => "balanced", "age_band" => "11-14", "glp_stage" => 4 },
      settings: {
        "pronouns" => "she/her",
        "headline" => "Big feelings, big vocabulary.",
        "device_notes" => "Ava navigates fast and knows her folders well — please don't \"help\" by tapping for her. She keeps her device on a lanyard. If she hands it to you, she wants you to read the message out loud.",
        "role_badges" => ["Communicator", "Gestalt Language Processor"],
        "show_email" => false,
        "allergies" => "Penicillin (rash + swelling). Mild seasonal pollen.",
        "medical_conditions" => "Autism; absence (petit mal) seizures.",
        "medications" => "Levetiracetam (Keppra), morning and night.",
        "emergency_notes" => "Ava's seizures look like brief staring spells (5–15 seconds) where she stops and blinks. Most pass on their own — note the time and keep her safe from stairs/edges. Call 911 if a seizure lasts over 5 minutes or they cluster back-to-back. As a gestalt language processor, Ava often communicates in scripted phrases (\"time to go home\") that may mean something different from the literal words — ask her to show you on her device. Loud, crowded rooms overwhelm her fast; a quiet corner and her AAC device help her regulate.",
        "ice_contact_1" => { "name" => "Grace Chen", "phone" => "(216) 555-0118", "relationship" => "Mother" },
        "ice_contact_2" => { "name" => "David Chen", "phone" => "(216) 555-0119", "relationship" => "Father" },
        "ice_contact_3" => { "name" => "Ms. Herrera (SLP)", "phone" => "(216) 555-0120", "relationship" => "Speech-language pathologist" }
      }
    },
    {
      name: "Jordan Whitfield",
      username: "jordan-whitfield",
      details: { "aac_level" => "proficient", "vocab_type" => "balanced", "age_band" => "adult", "glp_stage" => 6 },
      settings: {
        "pronouns" => "they/them",
        "headline" => "Same-old me — just louder now.",
        "device_notes" => "Jordan uses a rugged tablet on a wheelchair mount and communicates with AAC plus a few signs (more, done, help). Give them the full sentence before responding — they build longer messages than people expect. Charger lives in the side pouch.",
        "role_badges" => ["Communicator"],
        "show_email" => false,
        "allergies" => "Latex — use latex-free gloves only.",
        "medical_conditions" => "Autism; epilepsy (tonic-clonic seizures); Type 1 diabetes.",
        "medications" => "Lamotrigine (seizures); insulin (mealtime + long-acting). Has a VNS implant — magnet is clipped inside their bag.",
        "emergency_notes" => "For a tonic-clonic (grand mal) seizure: time it, ease them to the floor, cushion the head, turn on their side, do not restrain or put anything in their mouth. Swiping the VNS magnet across the chest device can help stop a seizure. Call 911 if it lasts over 5 minutes. Type 1 diabetes — if shaky, sweaty, or confused, that's likely low blood sugar; glucose gel is in the front bag pocket. Jordan is calm and social but needs extra processing time in stressful moments.",
        "ice_contact_1" => { "name" => "Patricia Whitfield", "phone" => "(216) 555-0173", "relationship" => "Mother / guardian" },
        "ice_contact_2" => { "name" => "Andre Whitfield", "phone" => "(216) 555-0174", "relationship" => "Brother" },
        "ice_contact_3" => { "name" => "Lakeside Adult Day Services", "phone" => "(216) 555-0150", "relationship" => "Day program" }
      }
    }
  ].freeze

  desc "Seed 3 fictional demo communicators as MySpeak pages (idempotent; USER_ID=N to override owner)"
  task myspeak_communicators: :environment do
    owner =
      if ENV["USER_ID"].present?
        User.find(ENV["USER_ID"])
      else
        # Devise :validatable requires an email + a password (6..128 chars).
        # plan_type/plan_status are real columns; setting plan_type "pro"
        # explicitly survives the before_create free-plan default (it only
        # fills a blank plan_type) and fires setup_pro_limits on save.
        User.find_or_create_by!(email: DEMO_OWNER_EMAIL) do |u|
          u.password = SecureRandom.alphanumeric(16)
          u.plan_type = "pro"
          u.plan_status = "active"
          u.settings ||= {}
        end
      end

    puts "== demo:myspeak_communicators == owner ##{owner.id} #{owner.email}"

    DEMO_COMMUNICATORS.each do |data|
      ca = ChildAccount.find_or_initialize_by(username: data[:username])
      created = ca.new_record?
      ca.name   = data[:name]
      # owner_id is the canonical ownership column (slot counts + team scope key);
      # user_id is set too as the legacy/optional alias, mirroring how the create
      # controller assigns a real communicator.
      ca.owner  = owner
      ca.user   = owner
      ca.status = ChildAccount::ACTIVE
      ca.passcode = SecureRandom.alphanumeric(8) if ca.passcode.blank?
      # AAC profile → details (typed; normalized/validated on save). The values
      # are already valid enums, so the merge round-trips them unchanged.
      ca.details = (ca.details || {}).merge(data[:details])
      ca.save!

      # create_profile! is a no-op when a profile already exists (re-run) and
      # doesn't populate the in-memory has_one cache on a fresh create, so read
      # through the return value / reload rather than a possibly-stale ca.profile.
      profile = ca.profile || ca.create_profile! || ca.reload.profile
      # Merge safety/public keys — never clobber, so a re-run is a no-op.
      profile.settings = (profile.settings || {}).merge(data[:settings])
      profile.save!

      puts "  #{created ? 'created' : 'updated'} ##{ca.id} #{ca.name} → /#{profile.slug} (safety_info=#{profile.has_safety_info?})"
    end

    puts "== Done."
  end
end
