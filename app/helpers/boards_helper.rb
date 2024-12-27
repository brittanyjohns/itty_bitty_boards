require "obf"
# res['name'] = hash['name']
#     res['default_layout'] = hash['default_layout'] || 'landscape'
#     res['background'] = hash['background']
#     res['url'] = hash['url']
#     res['data_url'] = hash['data_url']
#     OBF::Utils.log("compressing board #{res['name'] || res['id']}")

#     res['default_locale'] = hash['default_locale'] if hash['default_locale']
#     res['label_locale'] = hash['label_locale'] if hash['label_locale']
#     res['vocalization_locale'] = hash['vocalization_locale'] if hash['vocalization_locale']

#     res['description_html'] = hash['description_html']
#     res['protected_content_user_identifier'] = hash['protected_content_user_identifier'] if hash['protected_content_user_identifier']
#     res['license'] = OBF::Utils.parse_license(hash['license'])
module BoardsHelper
  def to_obf
    boards = []
    images = []
    sounds = []
    obf_board = OBF::Utils.obf_shell
    obf_board[:id] = self.id
    obf_board[:locale] = "en"
    obf_board[:name] = self.name
    obf_board[:format] = OBF::OBF::FORMAT
    obf_board[:default_layout] = "landscape"
    obf_board[:background] = self.background
    obf_board[:url] = self.url
    obf_board[:data_url] = self.data_url
    obf_board[:description_html] = self.description_html
    # obf_board[:protected_content_user_identifier] = self.protected_content_user_identifier
    obf_board[:license] = self.license
    obf_board[:default_locale] = self.default_locale
    obf_board[:label_locale] = self.label_locale
  end
end
