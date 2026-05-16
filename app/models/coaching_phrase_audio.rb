require "digest"

# Cached mp3 for a (text, voice, language) tuple. One row per unique tuple
# across the entire app — so a curated phrase like "Which one should WE eat?"
# in `polly:kevin` is synthesized exactly once, ever. Subsequent requests
# return the same ActiveStorage URL.
#
# == Schema Information
#
# Table name: coaching_phrase_audios
#
#  id         :bigint           not null, primary key
#  text       :text             not null
#  voice      :string           not null
#  language   :string           default("en"), not null
#  phrase_key  :string           not null  (unique index)
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class CoachingPhraseAudio < ApplicationRecord
  has_one_attached :audio

  validates :text, presence: true
  validates :voice, presence: true
  validates :language, presence: true
  validates :phrase_key, presence: true, uniqueness: true

  # Bump when the cache key formula changes (e.g., add speed) so we don't
  # serve stale audio from the old shape.
  CACHE_VERSION = "v1".freeze

  def self.phrase_key_for(text:, voice:, language: "en")
    normalized = [
      CACHE_VERSION,
      text.to_s.strip,
      voice.to_s.strip.downcase,
      language.to_s.strip.downcase,
    ].join("|")
    Digest::SHA256.hexdigest(normalized)
  end

  # Returns an existing record (with audio attached) or generates and persists
  # a new one. Concurrent callers race-safely via the unique index on
  # `phrase_key`: the loser of the race reloads the winner's row.
  def self.find_or_generate!(text:, voice:, language: "en")
    key = phrase_key_for(text: text, voice: voice, language: language)
    existing = find_by(phrase_key: key)
    return existing if existing&.audio&.attached?

    record = existing || new(
      text: text,
      voice: voice,
      language: language,
      phrase_key: key,
    )

    audio_io = synthesize(text: text, voice: voice, language: language)
    return nil unless audio_io

    audio_io = StringIO.new(audio_io) unless audio_io.respond_to?(:read)
    audio_io.rewind if audio_io.respond_to?(:rewind)

    record.audio.attach(
      io: audio_io,
      filename: filename_for(key: key),
      content_type: "audio/mpeg",
    )
    record.save!
    record
  rescue ActiveRecord::RecordNotUnique
    # Another request beat us to it; return the winner.
    find_by!(phrase_key: key)
  end

  def audio_url
    return nil unless audio.attached?

    if ENV["CDN_HOST"].present?
      "#{ENV["CDN_HOST"]}/#{audio.blob.key}"
    else
      Rails.application.routes.url_helpers.rails_blob_url(audio, only_path: false, host: ENV["FRONT_END_URL"] || "http://localhost:4000")
    end
  end

  def api_view
    {
      id: id,
      text: text,
      voice: voice,
      language: language,
      phrase_key: phrase_key,
      url: audio_url,
    }
  end

  def self.synthesize(text:, voice:, language:)
    return nil if Rails.env.test? && ENV["ALLOW_COACHING_AUDIO_TTS"] != "true"

    VoiceService.synthesize_speech(
      text: text,
      voice_value: voice,
      language: language,
    )
  rescue => e
    Rails.logger.error "[CoachingPhraseAudio] synth failed text=#{text.truncate(40)} voice=#{voice}: #{e.class} #{e.message}"
    nil
  end

  def self.filename_for(key:)
    "coaching_#{key.first(16)}.mp3"
  end
end
