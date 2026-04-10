class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
  include ActiveStorageSupport::SupportForBase64
  TILE_VARIANT_TRANSFORMATIONS = {
    resize_to_limit: [288, 288],
    format: :webp,
    saver: {
      quality: 65,
      strip: true,
    },
  }.freeze
end
