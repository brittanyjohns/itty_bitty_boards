# lib/tasks/demo_myspeak.rake
# Seed 3 fictional demo communicators as complete MySpeak pages: AAC profile,
# public intro headline + About Me bio, an unguessable random safety slug, and
# gated emergency/safety data. Idempotent / re-runnable. All data is fictional;
# phone numbers use the 555-01xx fiction range.
#
#   bundle exec rake demo:myspeak_communicators              # dedicated demo owner
#   bundle exec rake demo:myspeak_communicators USER_ID=740  # attach to a specific user
namespace :demo do
  DEMO_OWNER_EMAIL = "hello+demo@speakanyway.com".freeze

  DEMO_COMMUNICATORS = [
    {
      name: "Mateo Rivera",
      username: "mateo-rivera",
      intro: "Just getting started — and already unstoppable. 🦖",
      bio: "Hi, I'm Mateo! I'm 5 and I love dinosaurs, splashing in water, and anything with wheels. I'm just getting started with my talker, so I use single words, pointing, and lots of gestures — give me a beat and I'll get there. I understand way more than I can say yet. Sing \"Twinkle Twinkle\" with me and we'll be fast friends.",
      details: { "aac_level" => "emerging", "vocab_type" => "core", "age_band" => "4-6", "glp_stage" => 1 },
      settings: {
        "pronouns" => "he/him",
        "headline" => "Just getting started — and already unstoppable. 🦖",
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
      intro: "I script, I sketch, I speak my mind.",
      bio: "I'm Ava, I'm 12, and I have a lot to say. I love drawing manga, marine biology, and my cat Mochi. I'm a gestalt language processor, so sometimes I talk in scripts and phrases that mean more than the words — ask me and I'll show you on my device. I navigate my AAC app fast, so please don't tap for me. Quiet corners are my happy place.",
      details: { "aac_level" => "proficient", "vocab_type" => "balanced", "age_band" => "11-14", "glp_stage" => 4 },
      settings: {
        "pronouns" => "she/her",
        "headline" => "I script, I sketch, I speak my mind.",
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
      intro: "Same me, new voice — still the loudest laugh in the room.",
      bio: "Hey, I'm Jordan. I'm 27 and I use AAC plus a few signs to get my point across — I build longer sentences than people expect, so give me space to finish. I'm into basketball on TV, cooking shows, and hanging out at my day program. I'm easygoing and social; I just need a little extra time when things get stressful.",
      details: { "aac_level" => "proficient", "vocab_type" => "balanced", "age_band" => "adult", "glp_stage" => 6 },
      settings: {
        "pronouns" => "they/them",
        "headline" => "Same me, new voice — still the loudest laugh in the room.",
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

      # Build the MySpeak safety profile the way onboarding does (not
      # ChildAccount#create_profile!, which forces a name-derived slug): leave
      # `slug` blank so Profile#ensure_slug assigns an unguessable random
      # `s-xxxxxx` slug (slug_type "random"), matching real safety pages so a
      # child's /my/<slug> can't be found by guessing their name.
      profile = ca.profile || Profile.create!(
        profileable: ca,
        profile_kind: "safety",
        username: ca.username,
      )

      # Migrate any pre-existing name-derived (legacy) slug to a random one,
      # once. The slug_type guard keeps re-runs idempotent — a random slug is
      # never regenerated, so the URL is stable after the first migration.
      if profile.slug_type != "random"
        profile.slug = Profile.generate_random_slug
        profile.slug_type = "random"
      end

      # About Me (bio) + on-page intro headline are the PUBLIC blurbs the
      # safety page renders; overwrite to the seeded copy so the profile reads
      # as complete instead of Profile#set_defaults' placeholder text.
      profile.intro = data[:intro]
      profile.bio   = data[:bio]
      # Merge safety/public keys — never clobber, so a re-run is a no-op.
      profile.settings = (profile.settings || {}).merge(data[:settings])
      profile.save!

      # Generated initials avatar (Safety ID card + device tag embed it).
      profile.set_fake_avatar unless profile.avatar.attached?

      puts "  #{created ? 'created' : 'updated'} ##{ca.id} #{ca.name} → /#{profile.slug} " \
           "(slug_type=#{profile.slug_type} safety_info=#{profile.has_safety_info?})"
    end

    puts "== Done."
  end
end
