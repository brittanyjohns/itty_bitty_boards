# == Schema Information
#
# Table name: pg_search_documents
#
#  id              :bigint           not null, primary key
#  content         :text
#  searchable_type :string
#  searchable_id   :bigint
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
class PgSearchDocument < ApplicationRecord
end
