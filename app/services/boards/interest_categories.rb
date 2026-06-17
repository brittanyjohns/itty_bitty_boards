# app/services/boards/interest_categories.rb
#
# Maps an interest word -> the category folder it belongs in, for the hybrid
# Board Builder wizard (see Boards::BlueprintAssembler).
#
# Routing is keyed by the *folder label* used in the starter templates
# (Boards::StarterBlueprints), e.g. "Food" / "Feelings" / "Bathroom" / "Play".
# An interest only ever routes into a folder the chosen template actually has —
# the assembler checks folder presence and falls anything else through to the
# single "My Favorites" catch-all. So a word mapped to "Bathroom" still lands in
# Favorites on a template (like HOME) that has no Bathroom folder.
module Boards
  module InterestCategories
    # Folder label => the words that route into it. Words are matched
    # case-insensitively (stored lowercase). Keep words in exactly one list so
    # the reverse index below is unambiguous.
    KEYWORDS = {
      "Animals" => %w[
        dog cat horse fish bird rabbit snake bear turtle frog duck cow pig
        monkey elephant lion tiger shark whale dolphin puppy kitten hamster
        giraffe zebra penguin owl parrot spider ant bee butterfly octopus seal
        panda
      ],
      "Art & Craft" => %w[
        crayon marker paper stamp fold cut tape create make glue scissors
        stickers clay glitter sketch sculpt weave sew bead origami collage
        mosaic print
      ],
      "Bathroom" => %w[
        toilet potty wash soap towel bath shower brush teeth flush wipe diaper
        pee poop sink handwashing shampoo toothbrush toothpaste mirror
      ],
      "Clothing" => %w[
        shirt pants shoes hat socks jacket dress pajamas coat boots gloves
        scarf zipper button snap shorts skirt sweater hoodie uniform belt
        sandals slippers
      ],
      "Family & People" => %w[
        mom dad brother sister grandma grandpa friend teacher baby uncle aunt
        cousin neighbor therapist nurse helper caregiver nanny classmate
        teammate principal
      ],
      "Feelings" => %w[
        happy sad tired angry mad scared silly calm frustrated nervous proud
        shy sleepy sick hurt love worried surprised bored lonely grumpy excited
        cranky frightened upset jealous confused embarrassed brave gentle kind
        mean grateful hopeful anxious peaceful
      ],
      "Food" => %w[
        apple banana orange grapes grape strawberry strawberries watermelon
        water juice milk snack snacks cookie cookies pizza cracker crackers
        cheese yogurt cereal bread pasta noodles chicken rice carrot candy
        chocolate icecream sandwich soup egg eggs fruit drink hungry eat
        breakfast lunch dinner plate fork spoon cup bowl hot cold
      ],
      "Health & Body" => %w[
        doctor medicine stomach head hand foot eye ear nose mouth arm leg knee
        tummy back shoulder finger toe elbow wrist ankle chest belly throat
        neck brain heart
      ],
      "Home" => %w[
        bed table chair door window couch kitchen room floor stairs light
        fridge oven microwave blanket pillow lamp closet shelf drawer cabinet
        garage basement roof
      ],
      "Music" => %w[
        sing singing drum guitar piano song listen clap loud quiet music beat
        rhythm instrument tambourine xylophone trumpet flute violin ukulele
        maracas harmonica whistle choir band concert melody
      ],
      "Nature & Outdoors" => %w[
        tree flower sun rain snow garden rock dirt sky cloud wind leaf grass
        mud puddle pond river mountain camping hiking lake forest beach ocean
        sand wave shell star moon rainbow seed plant bug
      ],
      "Places" => %w[
        school store library hospital church pool playground zoo aquarium
        restaurant mall gym farm museum theater airport hotel market cafe
        bakery
      ],
      "Play" => %w[
        train trains dinosaur dinosaurs ball blocks block painting paint cars
        car books book puzzle puzzles doll dolls lego legos bike swing slide
        park game games drawing draw dance dancing bubbles animals truck trucks
        robot robots superhero princess art color colors coloring outside run
        toys pretend hide seek chase tag build climb
      ],
      "School" => %w[
        read write pencil homework class desk backpack recess test learn spell
        count alphabet number letter grade report project science history
        geography
      ],
      "Social" => %w[
        hi bye please thankyou sorry share turn wait mine yours stop go come
        look help want need like welcome together alone invite join agree
        disagree ask tell promise
      ],
      "Sports" => %w[
        swim kick throw catch jump race soccer basketball baseball football
        tennis gymnastics skateboard scooter yoga stretch wrestle hockey
        volleyball bowling karate surfing skiing snowboarding
      ],
      "Technology" => %w[
        tablet phone video computer movie app screen watch show headphones
        camera remote charge keyboard mouse printer internet website email
        message text photo selfie
      ],
      "Transportation" => %w[
        bus plane boat walk ride drive ambulance firetruck helicopter
        motorcycle subway taxi van wagon canoe ferry rocket sled tractor
        trolley
      ],
    }.freeze

    # Reverse index word -> category, built once at load for O(1) lookup.
    WORD_TO_CATEGORY = KEYWORDS.each_with_object({}) do |(category, words), map|
      words.each { |word| map[word] = category }
    end.freeze

    module_function

    # The category folder label for an interest word, or nil if it has no home.
    def category_for(word)
      WORD_TO_CATEGORY[word.to_s.strip.downcase]
    end

    # All category labels the lexicon knows about.
    def categories
      KEYWORDS.keys
    end
  end
end
