# frozen_string_literal: true

# Pure marketplace-copy primitives: Etsy's title rules, tag normalization, and
# tag assembly. No ENV, no network, no ActiveRecord — everything here is a
# string in, a string out, so it can be unit-tested on its own.
#
# Ported from speakanyway-printables `src/generator/listing-copy.ts`. Each
# constant and each odd-looking rule below is there because Etsy rejected (or
# silently mangled) a real listing; the comments name the failure so nobody
# "simplifies" one back out. Keep the two implementations in step — see
# .claude-notes/board-printables-etsy.md for the drift note.
module Etsy
  module CopyRules
    module_function

    # Etsy's hard caps.
    TITLE_MAX = 140
    TAG_MAX = 13
    TAG_LEN_MAX = 20

    DIGITAL_DOWNLOAD_SUFFIX = "(Digital Download)".freeze

    # Words that never earn a tag slot, and stay lowercase mid-title.
    SMALL_WORDS = %w[
      a an and as at but by for from in nor of on or the to vs with your my our
    ].to_set.freeze

    # Etsy rejects a listing title containing more than one "&":
    #   400 {"error":"There was a problem with /title/0 : & can only be use once"}
    # The first "&" is kept (it reads better than a third "and"); later ones
    # become "and".
    def enforce_title_rules(title)
      seen = 0
      title.to_s
           .gsub("&") { (seen += 1) <= 1 ? "&" : "and" }
           .gsub(/\s{2,}/, " ")
           .strip
    end

    # Append "(Digital Download)" unless already present, trimming to fit 140.
    def ensure_digital_download_suffix(title)
      title = title.to_s
      return title.rstrip if title =~ /\(digital download\)\s*\z/i

      suffix = " #{DIGITAL_DOWNLOAD_SUFFIX}"
      budget = TITLE_MAX - suffix.length
      base = title.length > budget ? title[0, budget].rstrip : title
      "#{base}#{suffix}"
    end

    # Title Case, leaving small words lowercase unless they lead the phrase.
    def title_case_words(raw)
      raw.to_s.strip.split(/\s+/).reject(&:empty?).each_with_index.map do |word, i|
        lower = word.downcase
        next lower if i.positive? && SMALL_WORDS.include?(lower)
        # Preserve deliberate capitalization like "AAC" / "ID".
        next word if word.length > 1 && word == word.upcase

        lower.sub(/\A./, &:upcase)
      end.join(" ")
    end

    # Normalize a phrase into an Etsy-legal tag, or nil if nothing usable
    # survives. Etsy allows letters, numbers, spaces, hyphens and apostrophes,
    # max 20 characters.
    def normalize_tag(phrase)
      cleaned = phrase.to_s.downcase.gsub(/[^a-z0-9 \-']/, " ").gsub(/\s+/, " ").strip
      return nil if cleaned.empty? || cleaned.length > TAG_LEN_MAX
      return nil if cleaned.split(" ").all? { |w| SMALL_WORDS.include?(w) }

      cleaned
    end

    # Mine keyword tags out of the free-text topic — the richest keyword source
    # a printable has.
    #
    # Each comma/slash-delimited segment is tried whole first. When a segment
    # exceeds the 20-char limit we fall back to its TRAILING phrase rather than
    # its leading one, because the head noun carries the search intent: "farm
    # and zoo animal vocabulary" yields "animal vocabulary", not "farm and".
    def topic_tags(topic)
      return [] if topic.blank?

      out = []
      push = ->(candidate) { out << candidate if candidate && !out.include?(candidate) }

      topic.split(%r{[/,;|]+}).each do |raw_segment|
        segment = raw_segment.strip
        next if segment.empty?

        whole = normalize_tag(segment)
        if whole
          push.call(whole)
          next
        end

        words = segment.downcase.gsub(/[^a-z0-9 \-']/, " ").split(/\s+/)
                       .reject { |w| w.empty? || SMALL_WORDS.include?(w) }
        [3, 2].each do |size|
          next if words.length < size

          push.call(normalize_tag(words.last(size).join(" ")))
        end
      end

      out
    end

    # Assemble the final tag list from the pools, in priority order, deduped and
    # normalized, capped at Etsy's 13.
    #
    # `top_up` is what fixes the real defect: the first four pools can only ever
    # yield ~6 tags for a typical AAC board — under half the allowance, with the
    # high-intent buyer language missing.
    def assemble_tags(always_on: [], product_type: [], audience: [], topic: [], top_up: [])
      tags = []
      add = lambda do |candidates|
        Array(candidates).each do |candidate|
          break if tags.length >= TAG_MAX

          tag = normalize_tag(candidate)
          tags << tag if tag && !tags.include?(tag)
        end
      end

      add.call(always_on)
      add.call(product_type)
      add.call(audience)
      add.call(topic)
      add.call(top_up)
      tags
    end

    # Pick the first candidate title that fits the cap once the
    # "(Digital Download)" suffix is accounted for, falling back through
    # progressively shorter forms.
    #
    # Callers MUST order candidates widest-first and MUST make the last one a
    # form that always fits (typically the bare board name) — a chain whose
    # every rung overflows gets truncated mid-word by
    # `ensure_digital_download_suffix`, which is how a shipped listing ended up
    # titled "… Printable for Speech The (Digital Download)".
    #
    # Candidates containing a stringified nil — the usual result of
    # interpolating an absent optional phrase — are skipped, not emitted.
    def pick_fitting_title(candidates)
      budget = TITLE_MAX - " #{DIGITAL_DOWNLOAD_SUFFIX}".length
      shortest = nil

      Array(candidates).each do |raw|
        candidate = raw.to_s.gsub(/\s{2,}/, " ").strip
        next if candidate.empty?
        next if candidate =~ /(\A|[,\s])(null|undefined|nil)([,\s]|\z)/

        return candidate if candidate.length <= budget

        shortest = candidate if shortest.nil? || candidate.length < shortest.length
      end

      # Everything overflowed — hand back the shortest so the caller's
      # truncation does as little damage as it can.
      shortest.to_s
    end

    TOPIC_PHRASE_MAX = 42

    # Pick the segment of the topic that adds the MOST words the title doesn't
    # already carry, so a composed title widens keyword coverage instead of
    # repeating itself. Returns nil when the topic adds nothing new.
    def distinct_topic_phrase(title:, topic:, product_human:)
      return nil if topic.blank?

      known = (title.to_s.split(/\s+/) + product_human.to_s.split(/\s+/))
              .map { |w| stem(w) }.reject(&:empty?).to_set

      best = nil
      topic.split(%r{[/,;|]+}).each do |raw_segment|
        phrase = raw_segment.strip
        next if phrase.empty? || phrase.length > TOPIC_PHRASE_MAX

        novel = phrase.split(/\s+/).count do |w|
          w.present? && !SMALL_WORDS.include?(w.downcase) && !known.include?(stem(w))
        end
        best = { phrase: phrase, novel: novel } if novel.positive? && (best.nil? || novel > best[:novel])
      end

      best ? title_case_words(best[:phrase]) : nil
    end

    # Loose stem so "animal" and "animals" count as the same word.
    def stem(word) = word.to_s.downcase.sub(/(ies|es|s)\z/, "")
  end
end
