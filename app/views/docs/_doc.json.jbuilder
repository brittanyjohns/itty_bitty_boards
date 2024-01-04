json.extract! doc, :id, :documentable_id, :documentable_type, :created_at, :updated_at
json.url doc_url(doc, format: :json)
