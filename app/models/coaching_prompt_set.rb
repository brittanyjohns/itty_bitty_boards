# == Schema Information
#
# Table name: coaching_prompt_sets
#
#  id          :bigint           not null, primary key
#  name        :string           not null
#  slug        :string           not null
#  description :text
#  strategies  :jsonb            not null
#  match_tags  :string           default([]), is an Array
#  source      :string           default("curated"), not null
#  user_id     :bigint
#  published   :boolean          default(TRUE), not null
#  language    :string           default("en"), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
class CoachingPromptSet < ApplicationRecord
  SOURCES = %w[curated ai_generated].freeze

  belongs_to :user, optional: true

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :source, inclusion: { in: SOURCES }
  validates :language, presence: true

  scope :published, -> { where(published: true) }
  scope :curated, -> { where(source: "curated") }
  scope :for_language, ->(lang) { where(language: lang) }

  # Best curated match for a board, based on tags + name keywords.
  # Returns nil when nothing matches.
  def self.match_for(board)
    return nil unless board

    lang = board.language.presence || "en"
    scope = published.curated.for_language(lang)

    tags = Array(board.try(:tags)).map { |t| t.to_s.downcase.strip }.reject(&:blank?)
    name_tokens = board.name.to_s.downcase.scan(/[a-z_]+/)

    candidates = tags + name_tokens
    return nil if candidates.empty?

    scope.find { |set| (Array(set.match_tags).map(&:downcase) & candidates).any? }
  end

  def curated?
    source == "curated"
  end

  def ai_generated?
    source == "ai_generated"
  end

  def api_view
    {
      id: id,
      name: name,
      slug: slug,
      description: description,
      strategies: strategies,
      match_tags: match_tags,
      source: source,
      user_id: user_id,
      published: published,
      language: language,
      editable_by_current_user: false,
    }
  end

  def api_view_for(current_user)
    view = api_view
    view[:editable_by_current_user] = editable_by?(current_user)
    view
  end

  def editable_by?(current_user)
    return false unless current_user
    return true if current_user.respond_to?(:admin?) && current_user.admin?
    user_id.present? && user_id == current_user.id
  end
end
