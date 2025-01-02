class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
  include ActiveStorageSupport::SupportForBase64
end
