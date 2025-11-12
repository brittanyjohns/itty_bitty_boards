# app/services/label_mapper.rb
class LabelMapper
  SYNONYMS = {
    "toilet" => "bathroom",
    "loo" => "bathroom",
    "wc" => "bathroom",
    "television" => "tv",
    "mommy" => "mom",
    "daddy" => "dad",
  }.freeze

  STOPWORDS = %w[the a an and to on at in of].freeze

  def self.normalize(str)
    s = (str || "").downcase.strip
    s = s.gsub(/[^\p{Alnum}\s'-]/, "")    # keep letters, numbers, spaces, hyphen, apostrophe
    s = s.split.reject { |w| STOPWORDS.include?(w) }.join(" ")
    SYNONYMS.fetch(s, s)
  end
end
