# SpeakAnyWay — Backend

Ruby on Rails 7 app (hybrid: API + HTML views). Deployed on EC2 via Hatchbox.

## Documentation Accuracy Rules

When writing or updating backend CLAUDE.md, ALWAYS verify claims against the actual codebase before writing. Specifically:
- Read Gemfile, config/application.rb, and routes.rb first
- Do NOT claim 'API-only' without checking config.api_only
- Do NOT add compliance claims (FedRAMP, HIPAA, SOC2) unless explicitly evidenced in code
- List actual major dependencies, not assumed ones

## Stack

- **Framework:** Rails 7
- **Language:** Ruby
- **Database:** PostgreSQL
- **Auth:** Devise + devise-jwt
- **Authorization:** Pundit
- **Background jobs:** Sidekiq (v7) + Redis
- **Payments:** Stripe and RevenueCat (via webhook)
- **File storage:** S3 (Active Storage)
- **Email:** Mailgun (via Action Mailer)
- **TTS/Audio:** AWS Polly
- **AI:** OpenAI API (`ruby-openai`) — board generation, scenario builder, image generation
- **Serializers:** jsonapi-serializer gem
- **Hosting:** Hatchbox / EC2

## Frontend

- React/Ionic frontend served separately (not via Rails asset pipeline)
- Communicates with Rails backend via JSON API endpoints
- Some HTML views for auth flows and admin dashboard, but most user-facing UI is React

## Routing

- Routes are mixed: some at root level, some under `/api/`, some under `/api/v1/`
- JSON API routes are generally under `namespace :api` (with `defaults: { format: :json }`)
- Auth routes (`/api/v1/`) live in `app/controllers/api/v1/`
- Do not assume all routes follow a single convention — check `config/routes.rb`

## Code conventions

- Standard Ruby style — no unnecessary metaprogramming
- Fat models, thin controllers
- Use snake_case everywhere (Ruby/Rails standard)

## Common commands

- `bin/dev` — start Rails server in development http://localhost:4000
- `bin/console` — open Rails console
- `bin/rails db:migrate` — run database migrations
- `bin/rails db:seed` — seed the database
- `bundle exec sidekiq` — start Sidekiq worker
- `bundle exec rspec` — run tests

## Subscription model

- Most features are free
- Premium features (Menu Board Creator, AI image generation) require active subscription
- Subscription managed via Stripe/RevenueCat — check status before allowing access to premium endpoints

## Do not

- Do not install new gems without asking first
- Do not modify any deployment or server config files
- Do not log sensitive user data
- Do not expose internal errors in API responses — return generic messages to the client
- Do not hardcode any environment-specific values (use ENV variables)

## Testing preferences:

- Prefer FactoryBot.build over create where possible
- Add focused tests for changed behavior
- Avoid destructive S3/ActiveStorage behavior in tests
- Add tests if missing for new features or bug fixes, but do not add tests for existing code unless explicitly asked

## Testing Conventions

- Rails test environment uses `:null_store` for Rails.cache — stub `Rails.cache` in specs that depend on caching behavior
- Avoid `travel_to` with past timestamps for Redis keys (TTLs expire immediately); use future times or freeze time instead
- After spec changes, run the full RSpec suite before declaring done

## Rules for Editing This File

When reviewing or rewriting CLAUDE.md, ALWAYS verify claims against the actual codebase first: read Gemfile/package.json, config files, routes, and a sampling of controllers/models. Never fabricate framework claims (e.g., 'API-only', 'FedRAMP-aware') or invent dependencies. If unsure, state 'unverified' rather than asserting.

## PR review guidelines:

Before pushing PRs, run the full RSpec suite locally and ensure 0 failures. When tests fail, distinguish spec bugs (factory/slug/cache/travel_to issues) from production bugs and fix both categories.

## Bash & Long-Running Commands

When running long bash commands (bundle update, migrations, test suites), use appropriate timeouts and check completion status explicitly rather than polling repeatedly.
