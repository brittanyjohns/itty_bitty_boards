module Images
  # Should THIS word's picture be drawn to look like the communicator?
  #
  # A likeness is a description of one specific person, and an image model reads
  # a described person as an instruction to draw one. Sent with every prompt on
  # a likeness board it put the communicator into "dog", and drew "she" and
  # "girl" as a boy who looked like them. So the likeness goes only where the
  # picture would naturally show a person AND that person would be the
  # communicator — the speaker doing, feeling or saying the word. Everything
  # else is ordinary art, generated exactly as it would be with no likeness.
  #
  # Deterministic on purpose (no AI call): the prompt, the doc's likeness stamp
  # and art reuse must all reach the same answer for the same word.
  module LikenessApplicability
    module_function

    # Words that name someone other than the speaker. Any one of them rules the
    # likeness out, even beside a first-person word ("me and mom"): with two
    # people in the picture there is no telling which should look like the
    # communicator. "we"/"us" too — a group drawn from one likeness is a crowd of
    # identical twins.
    OTHER_PERSON_WORDS = %w[
      she her hers herself he him his himself they them their theirs themselves
      we us our ours ourselves
      girl girls boy boys man men woman women lady gentleman person people
      kid kids child children baby babies toddler teenager
      mom mommy mum mother dad daddy father parent parents
      brother brothers sister sisters sibling siblings grandma grandpa grandmother
      grandfather granny nana papa aunt uncle cousin family son daughter
      husband wife
      friend friends teacher teachers doctor nurse dentist therapist coach
      classmate neighbor babysitter police officer firefighter
    ].to_set.freeze

    # The listener. Excluded as a subject ("you"), but not in something the
    # communicator SAYS to them ("thank you", "how are you?", "I love you").
    ADDRESSEE_WORDS = %w[you your yours yourself yourselves].to_set.freeze

    FIRST_PERSON_WORDS = %w[i me my mine myself].to_set.freeze

    # Parts of speech whose picture is someone doing, saying or gesturing it.
    PERSON_PARTS_OF_SPEECH = %w[verb social question important_function].to_set.freeze
    SPOKEN_PARTS_OF_SPEECH = %w[social question].to_set.freeze

    # Adjectives that describe how a PERSON feels. Every other adjective ("big",
    # "red", "hot", "full") is drawn on an object — "I'm cold" still takes the
    # likeness through its first-person word.
    FEELING_WORDS = %w[
      happy sad mad angry upset tired sleepy hungry thirsty scared afraid
      sick hurt excited bored silly calm worried nervous shy proud frustrated
      grumpy cranky lonely surprised confused embarrassed sore itchy
      sweaty dizzy jealous
    ].to_set.freeze

    def applies?(label:, part_of_speech:, user_input: nil)
      words = tokens(label) + tokens(user_input)
      return false if words.empty?

      pos = part_of_speech.to_s.strip.downcase
      first_person = words.any? { |word| FIRST_PERSON_WORDS.include?(word) }

      return false if words.any? { |word| OTHER_PERSON_WORDS.include?(word) }
      if words.any? { |word| ADDRESSEE_WORDS.include?(word) } &&
         !first_person && !SPOKEN_PARTS_OF_SPEECH.include?(pos)
        return false
      end

      return true if first_person
      return true if PERSON_PARTS_OF_SPEECH.include?(pos)

      pos == "adjective" && words.any? { |word| FEELING_WORDS.include?(word) }
    end

    # Lowercased words with contractions reduced to their base ("I'm" -> "i",
    # "she's" -> "she"), so punctuation never hides a person word.
    def tokens(text)
      text.to_s.downcase.tr("’", "'").scan(/[a-z]+(?:'[a-z]+)?/).map { |word| word.split("'").first }
    end
  end
end
