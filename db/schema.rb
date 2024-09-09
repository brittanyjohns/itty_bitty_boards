# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2024_09_08_195412) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "fuzzystrmatch"
  enable_extension "pg_trgm"
  enable_extension "pgcrypto"
  enable_extension "plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_id", "record_type", "name"], name: "idx_on_record_id_record_type_name_7af8b19b5e"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "beta_requests", force: :cascade do |t|
    t.string "email"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "details", default: {}
  end

  create_table "board_group_boards", force: :cascade do |t|
    t.bigint "board_group_id", null: false
    t.bigint "board_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["board_group_id"], name: "index_board_group_boards_on_board_group_id"
    t.index ["board_id"], name: "index_board_group_boards_on_board_id"
  end

  create_table "board_groups", force: :cascade do |t|
    t.string "name"
    t.jsonb "layout", default: {}
    t.boolean "predefined", default: false
    t.string "display_image_url"
    t.integer "position"
    t.integer "number_of_columns", default: 6
    t.integer "user_id", null: false
    t.string "bg_color"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "board_images", force: :cascade do |t|
    t.bigint "board_id", null: false
    t.bigint "image_id", null: false
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "voice"
    t.string "next_words", default: [], array: true
    t.string "bg_color"
    t.string "text_color"
    t.integer "font_size"
    t.string "border_color"
    t.jsonb "layout", default: {}
    t.string "status", default: "pending"
    t.string "audio_url"
    t.string "mode", default: "static"
    t.integer "dynamic_board_id"
    t.index ["board_id"], name: "index_board_images_on_board_id"
    t.index ["dynamic_board_id"], name: "index_board_images_on_dynamic_board_id"
    t.index ["image_id"], name: "index_board_images_on_image_id"
  end

  create_table "boards", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name"
    t.string "parent_type", null: false
    t.bigint "parent_id", null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "cost", default: 0
    t.boolean "predefined", default: false
    t.integer "token_limit", default: 0
    t.string "voice"
    t.string "status", default: "pending"
    t.integer "number_of_columns", default: 6
    t.integer "small_screen_columns", default: 3
    t.integer "medium_screen_columns", default: 8
    t.integer "large_screen_columns", default: 12
    t.string "display_image_url"
    t.jsonb "layout", default: {}
    t.integer "position"
    t.string "audio_url"
    t.string "bg_color"
    t.index ["parent_type", "parent_id"], name: "index_boards_on_parent"
    t.index ["user_id"], name: "index_boards_on_user_id"
  end

  create_table "child_accounts", force: :cascade do |t|
    t.string "username", default: "", null: false
    t.string "name", default: ""
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.integer "sign_in_count", default: 0, null: false
    t.datetime "current_sign_in_at"
    t.datetime "last_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "last_sign_in_ip"
    t.bigint "user_id", null: false
    t.string "authentication_token"
    t.jsonb "settings", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "passcode"
    t.index ["authentication_token"], name: "index_child_accounts_on_authentication_token", unique: true
    t.index ["reset_password_token"], name: "index_child_accounts_on_reset_password_token", unique: true
    t.index ["user_id"], name: "index_child_accounts_on_user_id"
    t.index ["username"], name: "index_child_accounts_on_username", unique: true
  end

  create_table "child_boards", force: :cascade do |t|
    t.bigint "board_id", null: false
    t.bigint "child_account_id", null: false
    t.string "status"
    t.jsonb "settings", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["board_id"], name: "index_child_boards_on_board_id"
    t.index ["child_account_id"], name: "index_child_boards_on_child_account_id"
  end

  create_table "docs", force: :cascade do |t|
    t.string "documentable_type", null: false
    t.bigint "documentable_id", null: false
    t.text "processed"
    t.text "raw"
    t.boolean "current", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "board_id"
    t.integer "user_id"
    t.string "source_type"
    t.datetime "deleted_at"
    t.string "original_image_url"
    t.index ["deleted_at"], name: "index_docs_on_deleted_at"
    t.index ["documentable_id", "documentable_type", "deleted_at"], name: "idx_on_documentable_id_documentable_type_deleted_at_a6715ad541"
    t.index ["documentable_type", "documentable_id"], name: "index_docs_on_documentable"
    t.index ["user_id"], name: "index_docs_on_user_id"
  end

  create_table "images", force: :cascade do |t|
    t.string "label"
    t.text "image_prompt"
    t.text "display_description"
    t.boolean "private"
    t.integer "user_id"
    t.boolean "generate_image", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "status"
    t.string "error"
    t.string "revised_prompt"
    t.string "image_type"
    t.string "open_symbol_status", default: "active"
    t.string "next_words", default: [], array: true
    t.boolean "no_next", default: false
    t.string "part_of_speech"
    t.string "bg_color"
    t.string "text_color"
    t.integer "font_size"
    t.string "border_color"
    t.boolean "is_private", default: false
    t.string "audio_url"
  end

  create_table "menus", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name"
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "token_limit", default: 0
    t.boolean "predefined", default: false
    t.text "raw"
    t.string "item_list", default: [], array: true
    t.text "prompt_sent"
    t.text "prompt_used"
    t.index ["user_id"], name: "index_menus_on_user_id"
  end

  create_table "messages", force: :cascade do |t|
    t.string "subject"
    t.text "body"
    t.integer "user_id"
    t.string "user_email"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "open_symbols", force: :cascade do |t|
    t.string "label"
    t.string "image_url"
    t.string "search_string"
    t.string "symbol_key"
    t.string "name"
    t.string "locale"
    t.string "license_url"
    t.string "license"
    t.integer "original_os_id"
    t.string "repo_key"
    t.string "unsafe_result"
    t.string "protected_symbol"
    t.string "use_score"
    t.string "relevance"
    t.string "extension"
    t.boolean "enabled"
    t.string "author"
    t.string "author_url"
    t.string "source_url"
    t.string "details_url"
    t.string "hc"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "openai_prompts", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.text "prompt_text"
    t.text "revised_prompt"
    t.boolean "send_now", default: false
    t.datetime "deleted_at"
    t.datetime "sent_at"
    t.boolean "private", default: false
    t.string "age_range"
    t.integer "token_limit"
    t.string "response_type"
    t.text "description"
    t.integer "number_of_images", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "prompt_template_id"
    t.string "name"
    t.index ["deleted_at"], name: "index_openai_prompts_on_deleted_at"
    t.index ["prompt_template_id"], name: "index_openai_prompts_on_prompt_template_id"
    t.index ["sent_at"], name: "index_openai_prompts_on_sent_at"
    t.index ["user_id"], name: "index_openai_prompts_on_user_id"
  end

  create_table "order_items", force: :cascade do |t|
    t.bigint "product_id", null: false
    t.bigint "order_id", null: false
    t.decimal "unit_price"
    t.integer "quantity"
    t.decimal "total_price"
    t.integer "total_coin_value"
    t.integer "coin_value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["product_id"], name: "index_order_items_on_product_id"
  end

  create_table "orders", force: :cascade do |t|
    t.decimal "subtotal"
    t.decimal "tax"
    t.decimal "shipping"
    t.decimal "total"
    t.integer "status", default: 0
    t.bigint "user_id", null: false
    t.integer "total_coin_value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_orders_on_user_id"
  end

  create_table "pay_charges", force: :cascade do |t|
    t.bigint "customer_id", null: false
    t.bigint "subscription_id"
    t.string "processor_id", null: false
    t.integer "amount", null: false
    t.string "currency"
    t.integer "application_fee_amount"
    t.integer "amount_refunded"
    t.jsonb "metadata"
    t.jsonb "data"
    t.string "stripe_account"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["customer_id", "processor_id"], name: "index_pay_charges_on_customer_id_and_processor_id", unique: true
    t.index ["subscription_id"], name: "index_pay_charges_on_subscription_id"
  end

  create_table "pay_customers", force: :cascade do |t|
    t.string "owner_type"
    t.bigint "owner_id"
    t.string "processor", null: false
    t.string "processor_id"
    t.boolean "default"
    t.jsonb "data"
    t.string "stripe_account"
    t.datetime "deleted_at", precision: nil
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_type", "owner_id", "deleted_at"], name: "pay_customer_owner_index", unique: true
    t.index ["processor", "processor_id"], name: "index_pay_customers_on_processor_and_processor_id", unique: true
  end

  create_table "pay_merchants", force: :cascade do |t|
    t.string "owner_type"
    t.bigint "owner_id"
    t.string "processor", null: false
    t.string "processor_id"
    t.boolean "default"
    t.jsonb "data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_type", "owner_id", "processor"], name: "index_pay_merchants_on_owner_type_and_owner_id_and_processor"
  end

  create_table "pay_payment_methods", force: :cascade do |t|
    t.bigint "customer_id", null: false
    t.string "processor_id", null: false
    t.boolean "default"
    t.string "type"
    t.jsonb "data"
    t.string "stripe_account"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["customer_id", "processor_id"], name: "index_pay_payment_methods_on_customer_id_and_processor_id", unique: true
  end

  create_table "pay_subscriptions", force: :cascade do |t|
    t.bigint "customer_id", null: false
    t.string "name", null: false
    t.string "processor_id", null: false
    t.string "processor_plan", null: false
    t.integer "quantity", default: 1, null: false
    t.string "status", null: false
    t.datetime "current_period_start", precision: nil
    t.datetime "current_period_end", precision: nil
    t.datetime "trial_ends_at", precision: nil
    t.datetime "ends_at", precision: nil
    t.boolean "metered"
    t.string "pause_behavior"
    t.datetime "pause_starts_at", precision: nil
    t.datetime "pause_resumes_at", precision: nil
    t.decimal "application_fee_percent", precision: 8, scale: 2
    t.jsonb "metadata"
    t.jsonb "data"
    t.string "stripe_account"
    t.string "payment_method_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["customer_id", "processor_id"], name: "index_pay_subscriptions_on_customer_id_and_processor_id", unique: true
    t.index ["metered"], name: "index_pay_subscriptions_on_metered"
    t.index ["pause_starts_at"], name: "index_pay_subscriptions_on_pause_starts_at"
  end

  create_table "pay_webhooks", force: :cascade do |t|
    t.string "processor"
    t.string "event_type"
    t.jsonb "event"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "pg_search_documents", force: :cascade do |t|
    t.text "content"
    t.string "searchable_type"
    t.bigint "searchable_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["searchable_type", "searchable_id"], name: "index_pg_search_documents_on_searchable"
  end

  create_table "predefined_resources", force: :cascade do |t|
    t.string "name"
    t.string "resource_type"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "product_categories", force: :cascade do |t|
    t.string "name"
    t.string "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "products", force: :cascade do |t|
    t.string "name"
    t.decimal "price"
    t.boolean "active"
    t.bigint "product_category_id", null: false
    t.text "description"
    t.integer "coin_value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_category_id"], name: "index_products_on_product_category_id"
  end

  create_table "prompt_templates", force: :cascade do |t|
    t.string "prompt_type"
    t.string "template_name"
    t.string "name"
    t.string "response_type"
    t.text "prompt_text"
    t.text "revised_prompt"
    t.text "preprompt_text"
    t.string "method_name"
    t.boolean "current", default: false
    t.integer "quantity", default: 8
    t.jsonb "config", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "scenarios", force: :cascade do |t|
    t.json "questions"
    t.json "answers"
    t.string "name"
    t.text "initial_description"
    t.string "age_range"
    t.bigint "user_id", null: false
    t.string "status", default: "pending"
    t.string "word_list", default: [], array: true
    t.integer "token_limit", default: 10
    t.integer "board_id"
    t.boolean "send_now", default: false
    t.integer "number_of_images", default: 0
    t.integer "tokens_used", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_scenarios_on_user_id"
  end

  create_table "subscriptions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "stripe_subscription_id"
    t.string "stripe_plan_id"
    t.string "status"
    t.datetime "expires_at"
    t.integer "price_in_cents"
    t.string "interval", default: "month"
    t.string "stripe_customer_id"
    t.integer "interval_count", default: 1
    t.string "stripe_invoice_id"
    t.string "stripe_client_reference_id"
    t.string "stripe_payment_status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_subscriptions_on_user_id"
  end

  create_table "team_boards", force: :cascade do |t|
    t.bigint "board_id", null: false
    t.bigint "team_id", null: false
    t.boolean "allow_edit", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["board_id"], name: "index_team_boards_on_board_id"
    t.index ["team_id"], name: "index_team_boards_on_team_id"
  end

  create_table "team_users", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "team_id", null: false
    t.string "role"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "invitation_accepted_at"
    t.datetime "invitation_sent_at"
    t.boolean "can_edit", default: false
    t.index ["team_id"], name: "index_team_users_on_team_id"
    t.index ["user_id"], name: "index_team_users_on_user_id"
  end

  create_table "teams", force: :cascade do |t|
    t.string "name"
    t.integer "created_by", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "user_docs", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "doc_id", null: false
    t.integer "image_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["doc_id"], name: "index_user_docs_on_doc_id"
    t.index ["user_id"], name: "index_user_docs_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.integer "sign_in_count", default: 0, null: false
    t.datetime "current_sign_in_at"
    t.datetime "last_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "last_sign_in_ip"
    t.string "name"
    t.string "role"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "tokens", default: 0
    t.string "stripe_customer_id"
    t.string "authentication_token"
    t.string "jti", null: false
    t.string "invitation_token"
    t.datetime "invitation_created_at"
    t.datetime "invitation_sent_at"
    t.datetime "invitation_accepted_at"
    t.integer "invitation_limit"
    t.integer "invited_by_id"
    t.string "invited_by_type"
    t.bigint "current_team_id"
    t.boolean "play_demo", default: true
    t.jsonb "settings", default: {}
    t.string "base_words", default: [], array: true
    t.string "plan_type", default: "free"
    t.datetime "plan_expires_at"
    t.string "plan_status", default: "active"
    t.decimal "monthly_price", precision: 8, scale: 2, default: "0.0"
    t.decimal "yearly_price", precision: 8, scale: 2, default: "0.0"
    t.decimal "total_plan_cost", precision: 8, scale: 2, default: "0.0"
    t.uuid "uuid", default: -> { "gen_random_uuid()" }
    t.string "child_lookup_key"
    t.index ["authentication_token"], name: "index_users_on_authentication_token", unique: true
    t.index ["child_lookup_key"], name: "index_users_on_child_lookup_key", unique: true
    t.index ["current_team_id"], name: "index_users_on_current_team_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["invitation_token"], name: "index_users_on_invitation_token", unique: true
    t.index ["jti"], name: "index_users_on_jti", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["uuid"], name: "index_users_on_uuid", unique: true
  end

  create_table "word_events", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "word"
    t.string "previous_word"
    t.integer "board_id"
    t.integer "team_id"
    t.datetime "timestamp"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "child_account_id"
    t.index ["child_account_id"], name: "index_word_events_on_child_account_id"
    t.index ["user_id"], name: "index_word_events_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "board_group_boards", "board_groups"
  add_foreign_key "board_group_boards", "boards"
  add_foreign_key "board_images", "boards"
  add_foreign_key "board_images", "images"
  add_foreign_key "boards", "users"
  add_foreign_key "child_accounts", "users"
  add_foreign_key "child_boards", "boards"
  add_foreign_key "child_boards", "child_accounts"
  add_foreign_key "menus", "users"
  add_foreign_key "openai_prompts", "users"
  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "products"
  add_foreign_key "orders", "users"
  add_foreign_key "pay_charges", "pay_customers", column: "customer_id"
  add_foreign_key "pay_charges", "pay_subscriptions", column: "subscription_id"
  add_foreign_key "pay_payment_methods", "pay_customers", column: "customer_id"
  add_foreign_key "pay_subscriptions", "pay_customers", column: "customer_id"
  add_foreign_key "products", "product_categories"
  add_foreign_key "scenarios", "users"
  add_foreign_key "subscriptions", "users"
  add_foreign_key "team_boards", "boards"
  add_foreign_key "team_boards", "teams"
  add_foreign_key "team_users", "teams"
  add_foreign_key "team_users", "users"
  add_foreign_key "user_docs", "docs"
  add_foreign_key "user_docs", "users"
  add_foreign_key "word_events", "users"
end
