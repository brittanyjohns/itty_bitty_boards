# Canonical curated content for caregiver coaching prompts.
# Used by db/seeds.rb and by CoachingPromptGenerator's transient fallback,
# so a copy of these phrases lives in exactly one place.
module CoachingPromptSeedData
  DEFAULT_FALLBACK_STRATEGIES = [
    {
      "label" => "Offer a choice",
      "hint" => "Give two options instead of a yes/no question.",
      "example_phrases" => ["Should we pick this one or that one?", "Which one do you want?"],
    },
    {
      "label" => "Pause and wait",
      "hint" => "Count silently to five after asking. Give them time to answer.",
      "example_phrases" => ["I'll wait.", "Take your time."],
    },
    {
      "label" => "Model a feeling word",
      "hint" => "Say how something feels — happy, silly, soft, cold.",
      "example_phrases" => ["That sounds funny.", "I feel happy when we do this."],
    },
    {
      "label" => "Comment, don't quiz",
      "hint" => "Notice what they're doing out loud instead of testing them.",
      "example_phrases" => ["You picked the red one!", "I see you're looking at the dog."],
    },
  ].freeze

  SNACK_TIME = {
    slug: "snack_time",
    name: "Snack Time",
    description: "Turn a snack into a chance to connect.",
    match_tags: %w[snack snack_time food eating meal kitchen],
    strategies: [
      {
        "label" => "Offer a choice",
        "hint" => "Hold up two options and let them pick.",
        "example_phrases" => [
          "Which one should WE eat?",
          "Do you want crunchy or soft?",
          "Apple or banana?",
        ],
      },
      {
        "label" => "Model a feeling word",
        "hint" => "Say what the food feels or tastes like out loud.",
        "example_phrases" => [
          "I like this.",
          "Mmm, this is cold!",
          "The crunchy one is my favorite.",
        ],
      },
      {
        "label" => "Pause and wait",
        "hint" => "Ask a question, then count silently to five.",
        "example_phrases" => [
          "I wonder which one you'll pick.",
          "I'll wait — take your time.",
        ],
      },
      {
        "label" => "Ask an opinion",
        "hint" => "Skip the yes/no — invite their opinion.",
        "example_phrases" => [
          "Do you think grandma would like this?",
          "Which one do you think is the best?",
        ],
      },
      {
        "label" => "Encourage storytelling",
        "hint" => "Connect the snack to something they've done before.",
        "example_phrases" => [
          "Remember when we made cookies?",
          "Tell me about the last time you ate this.",
        ],
      },
    ],
  }.freeze

  CAR_RIDE = {
    slug: "car_ride",
    name: "Car Ride",
    description: "Turn passive time into language-rich interaction.",
    match_tags: %w[car car_ride drive driving travel commute],
    strategies: [
      {
        "label" => "Comment on what you see",
        "hint" => "Notice things out loud — no answer required.",
        "example_phrases" => [
          "That truck is loud.",
          "I see a dog!",
          "Look at all the leaves.",
        ],
      },
      {
        "label" => "Encourage prediction",
        "hint" => "Wonder what might happen next.",
        "example_phrases" => [
          "Where do you think we're going?",
          "What do you think we'll see next?",
        ],
      },
      {
        "label" => "Model a feeling word",
        "hint" => "Say how the moment feels.",
        "example_phrases" => [
          "That was funny.",
          "I feel happy with you.",
          "That siren is so loud — a little scary!",
        ],
      },
      {
        "label" => "Pause and wait",
        "hint" => "After commenting, leave space for them to respond.",
        "example_phrases" => [
          "I wonder what you'll spot first.",
          "Hmm…",
        ],
      },
      {
        "label" => "Connect to real life",
        "hint" => "Relate what you see to something they know.",
        "example_phrases" => [
          "That looks like grandpa's truck.",
          "We saw a horse like that at the farm, remember?",
        ],
      },
    ],
  }.freeze

  BEDTIME_STORY = {
    slug: "bedtime_story",
    name: "Bedtime Story",
    description: "Read together in a way that invites real conversation.",
    match_tags: %w[bedtime bedtime_story story book reading night],
    strategies: [
      {
        "label" => "Encourage prediction",
        "hint" => "Pause and wonder what happens next.",
        "example_phrases" => [
          "What do YOU think happens next?",
          "Uh oh — what should they do?",
        ],
      },
      {
        "label" => "Talk about feelings",
        "hint" => "Notice the character's feelings out loud.",
        "example_phrases" => [
          "Do you think he feels sad?",
          "She looks excited!",
          "I'd be a little scared.",
        ],
      },
      {
        "label" => "Connect to real life",
        "hint" => "Tie the story to something they've done.",
        "example_phrases" => [
          "That reminds me of when we went to the park.",
          "We have a blanket like that one.",
        ],
      },
      {
        "label" => "Comment, don't quiz",
        "hint" => "Skip the 'what color is the bear?' — say what you notice.",
        "example_phrases" => [
          "I love how soft this bear looks.",
          "Look at that moon!",
        ],
      },
      {
        "label" => "Pause and wait",
        "hint" => "Stop after a page. Let them point or talk.",
        "example_phrases" => [
          "Hmm…",
          "I wonder what you see on this page.",
        ],
      },
    ],
  }.freeze

  CURATED_SETS = [SNACK_TIME, CAR_RIDE, BEDTIME_STORY].freeze
end
