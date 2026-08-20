# frozen_string_literal: true

# The cheap, per-listing SEO checks an admin should see before publishing,
# rendered in the same panel as Etsy::TagOverlap.
#
# ADVISORY ONLY — nothing here blocks a save or a publish, for the same reason
# TagOverlap doesn't: each check has legitimate exceptions only a human can
# judge, and a listing that can't be published is worse than one published with
# twelve tags.
#
# Read-only and side-effect free — safe to call from a view.
module Etsy
  class CopyAdvisories
    # The phrase every title must lead with. All seven titles hand-rewritten on
    # 2026-08-20 open on "AAC"; the zero-view ones opened on a niche noun
    # ("Recess", "Haircut") and buried the searched term. 40 characters is about
    # where Etsy's search results and the browser tab stop showing a title, so
    # a head term past it is a head term nobody reads.
    HEAD_TERM = /\baac\b/i
    HEAD_TERM_WINDOW = 40

    Advisory = Struct.new(:key, :message, :detail, keyword_init: true)

    def initialize(listing)
      @listing = listing || {}
    end

    def any? = advisories.any?

    def advisories
      @advisories ||= [short_tag_set, single_word_tags, buried_head_term].compact
    end

    private

    def tags = @tags ||= Array(@listing["tags"]).map { |tag| tag.to_s.strip }.reject(&:empty?)

    def title = @listing["title"].to_s

    # Etsy gives thirteen slots and charges nothing for using them; an unused
    # slot is a search query this listing can never be found by.
    def short_tag_set
      return if tags.length >= CopyRules::TAG_MAX

      Advisory.new(
        key: :short_tag_set,
        message: "Only #{tags.length} of #{CopyRules::TAG_MAX} tag slots are used.",
        detail: "Every empty slot is a search this listing can't appear in. Add a phrase.",
      )
    end

    # Generation can no longer produce one — CopyRules.normalize_tag refuses it
    # — but a tag saved before that rule existed is still sitting in the jsonb.
    def single_word_tags
      offenders = tags.select { |tag| tag.split(/\s+/).length < 2 }
      return if offenders.empty?

      Advisory.new(
        key: :single_word_tags,
        message: "#{offenders.length} single-word #{'tag'.pluralize(offenders.length)}: " \
                 "#{offenders.join(', ')}.",
        detail: "One-word tags compete with the whole marketplace and don't rank. " \
                "Replace each with a phrase a buyer would actually type.",
      )
    end

    def buried_head_term
      return if title.blank?
      return if title[0, HEAD_TERM_WINDOW] =~ HEAD_TERM

      Advisory.new(
        key: :buried_head_term,
        message: "The title's first #{HEAD_TERM_WINDOW} characters don't say \"AAC\".",
        detail: "Lead with \"AAC\" and fold the board name in right after it — the shop grid " \
                "truncates around 34 characters, so the head term and the board name both need " \
                "to land inside that window.",
      )
    end
  end
end
