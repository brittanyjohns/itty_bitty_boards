# Speak Anyway

## Empowering communication through the power of AI

- Ruby version: 2.6.3

- System dependencies:

  - postgresql
  - redis
  - imagemagick
  - ffmpeg

- Environment Variables:

  - `AWS_ACCESS_KEY_ID` - AWS Access Key ID
  - `AWS_SECRET_ACCESS_KEY` - AWS Secret Access Key
  - `AWS_REGION` - AWS Region
  - `OPENAI_ACCESS_TOKEN` - OpenAI Access Token
  - `OPENAI_ORGANIZATION` - OpenAI Organization (optional)
  - `STRIPE_PUBLIC_KEY` - Stripe Public Key
  - `STRIPE_PRIVATE_KEY` - Stripe Private Key
  - `STRIPE_SIGNING_SECRET` - Stripe Signing Secret

- Database creation:

  - `rails db:create`
  - `rails db:migrate`

- Database initialization:

  - `rails db:seed`

- How to run the test suite:

  - WIP

- Services (job queues, cache servers, search engines, etc.):

  - `redis-server`
  - `bundle exec sidekiq`

- Deployment instructions:
  Deployed to Hatchbox.io

Features

Multiple ways of creating a communication board

- By hand: Add words one at a time
- From a word list: Input a list of words to create images from
- From a scenario: Describe a scenario and we'll use AI to generate a list of words
- From a menu: Upload a menu and we'll use AI to generate a communication board - Order with confidence!

AI powered word suggestions

- Use our AI to suggest words based on a scenario
- Use our AI to suggest words based on a list of words

Customizable communication boards

- Made to fit any size screen - Unique layouts for each screen size (small, medium, large)
- Resizable cells to provide emphasis or easy access to common selections
- Choose from 6 natural sounding voices
- Colored cells based on part of speech

Images - Search, upload, or generate images for your boards

- Search for images with our built-in Google image search
- Upload your own images
- Generate images from text using AI
- Browse our library of images

Child accounts

- Create child accounts to manage their access & content
- Share boards with child accounts
- Monitor usage and progress
- View usage statistics & word patterns
- Manage everything from your parent account, on any device
- Update boards in real-time

Subscription based service

- Free trial available
- Monthly or yearly subscription options
- Cancel anytime
