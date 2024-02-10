# == Schema Information
#
# Table name: open_symbols
#
#  id               :bigint           not null, primary key
#  label            :string
#  image_url        :string
#  search_string    :string
#  symbol_key       :string
#  name             :string
#  locale           :string
#  license_url      :string
#  license          :string
#  original_os_id   :integer
#  repo_key         :string
#  unsafe_result    :string
#  protected_symbol :string
#  use_score        :string
#  relevance        :string
#  extension        :string
#  enabled          :boolean
#  author           :string
#  author_url       :string
#  source_url       :string
#  details_url      :string
#  hc               :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
class OpenSymbol < ApplicationRecord
    has_many :docs, as: :documentable, dependent: :destroy

    # after_save :set_image, unless: :has_matching_image?

    def set_image
        if !self.image_url.blank?
            # self.save_symbol_image
            self.add_to_matching_image
        end
    end

    def image
        if docs.any?
            docs.last.image
        end
    end

    def image_doc
        if docs.any?
            docs.last
        end
    end

    def matching_image
        matching_image = Image.find_by(label: self.label, private: [false, nil])
        return unless matching_image && matching_image.docs.where(processed: self.name.parameterize, raw: self.search_string).any?
        matching_image
    end

    def has_matching_image?
        matching_image = Image.find_by(label: self.label, private: [false, nil])
        return unless matching_image
        matching_image.docs.where(processed: self.name.parameterize, raw: self.search_string).any?
    end

    def self.post_open_symbols_token(access_token)
        uri = URI("https://www.opensymbols.org/api/v2/token?secret=#{access_token}")
        response = Net::HTTP.post(uri, '')
  
        response
      end

    def self.get_token
        open_symbol_access_token = ENV["OPEN_SYMBOL_ACCESS_TOKEN"]
        # make post request to get token
        response = post_open_symbols_token(open_symbol_access_token)
        if response.code == "200"
          response_body = JSON.parse(response.body)
          @open_symbol_id_token = response_body["access_token"]
        else
          puts "ERROR response: #{response.inspect}"
          puts "ERROR response.body: #{response.body}"
          nil
        end
    end

    def self.generate_symbol(query)
      @open_symbol_id_token = open_symbol_id_token
      token_to_send = CGI.escape(@open_symbol_id_token)
      query_to_send = CGI.escape(query)
      uri = URI("https://www.opensymbols.org/api/v2/symbols?access_token=#{token_to_send}&q=#{query_to_send}")
      response = Net::HTTP.get(uri)

      response
    end

    def self.open_symbol_id_token(refresh = false)
        if @open_symbol_id_token.nil? || refresh
          self.get_token
        end
        puts "Returning open_symbol_id_token: #{@open_symbol_id_token}"
        @open_symbol_id_token
      end

    def add_to_matching_image
        return if has_matching_image?
        matching_image = Image.find_by(label: self.label, private: [false, nil])
        downloaded_image = get_downloaded_image
        puts "Downloaded Image: #{downloaded_image.inspect}"
        if matching_image
            new_image_doc = matching_image.docs.create!(processed: self.name.parameterize, raw: self.search_string, source_type: "OpenSymbol")
        else
            new_image = Image.create!(label: self.label, private: false)
            new_image_doc = new_image.docs.create!(processed: self.name.parameterize, raw: self.search_string, source_type: "OpenSymbol")
        end
        new_image_doc.image.attach(io: downloaded_image, filename: "#{self.name.parameterize}-symbol-#{self.id}.#{self.extension}")

    end

    IMAGE_EXTENSIONS = %w(jpg jpeg gif png)

    def image_extension?
        IMAGE_EXTENSIONS.include?(self.extension)
    end

    def get_downloaded_image
        return if !image_extension?
        url = self.image_url.gsub(" ", "%20")
        puts "****\n\n\nURL: #{url}"
        return unless url
        downloaded_img = URI.open(url,
            "User-Agent" => "Ruby/#{RUBY_VERSION}",
            "From" => "foo@bar.invalid",
            "Referer" => "http://www.ruby-lang.org/")
        if downloaded_img
            return downloaded_img
        else
            raise "OpenSymbol ERROR: Image not found"
        end
    end

    def save_symbol_image
        return if !image_extension?
        begin
            downloaded_image = get_downloaded_image
            doc = self.docs.create!(processed: self.name.parameterize, raw: self.search_string, source_type: "OpenSymbol")
            doc.image.attach(io: downloaded_image, filename: "#{self.name.parameterize}-symbol-#{self.id}.#{self.extension}")
        rescue => e
            puts "OpenSymbol ERROR: #{e.inspect}"
            raise e
        end
    end

end
