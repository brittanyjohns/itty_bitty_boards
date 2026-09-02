# Changelog

All notable user-facing changes to this project will be documented here.
The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- **A copied or assigned board looks like the board it came from.** Tiles whose
  picture was set per-tile — a text image (the tile's word rendered as the
  picture), a picture picked from the tile's gallery, a custom upload — came
  back showing the shared library symbol instead, so copying a board or
  assigning it to a communicator quietly undid that work. Those pictures now
  travel with the copy, as does a tile's font size. Tiles with "Hide pictures"
  on were already handled and still are. Boards copied before this fix are
  unchanged; re-apply the text image on those tiles to fix them.
- **Importing an OBF/OBZ board no longer gives a picture-less button the
  previous button's picture.**

### Changed

- **A failed payment now says why it failed.** The past-due notice could only
  say "payment failed", which is the wrong advice for half of the cases — a
  bank that declines an otherwise-valid card can't be fixed by re-saving that
  card in the billing portal. The app now records the reason behind a failed
  renewal (out of funds, expired card, wrong card details, or the bank
  declining it) so the notice can point at the action that actually helps.
  Fraud-flagged declines are deliberately reported as a plain failure rather
  than by name.

- **Approved clinicians can lend a communicator to a family again.** The
  Clinician plan advertises 2 loaner slots, but the server-side gate on
  "Lend & hand off" checked for Pro — and Clinician is deliberately not Pro, so
  every lend was refused. Setting up a trial communicator, handing it to a
  family, and getting the slot back when they claim it now works end to end on
  a Clinician account. Nothing changed for Free or Basic, and the slot count is
  unchanged: a clinician still lends within their 2 slots.
- **Hitting the communicator cap now says which cap and how many.** The 422 was
  a bare "Maximum number of communicator accounts reached." with no number and
  no next step. It now also carries a machine-readable code and the plan's
  limit and current count, so the app can show "2 of 2" and offer a way
  forward. The existing message text is unchanged.
- **Transactional emails are now traceable.** Every message the app hands to
  the mail server is logged with its recipient and Message-ID, and a delivery
  failure is logged with a distinct tag instead of a generic background-job
  error. This does not change whether mail is delivered — it makes a missing
  email diagnosable, which it previously was not from inside the app.
- **Emails no longer all say "Welcome to SpeakAnyWay!" in the title.** The
  shared mail layout hardcoded that title on every message, including admin
  alerts, so some mail clients showed an admin notification about a new
  clinician application under a welcome header.

- **Menu board tiles are now white.** A menu board's tiles are dishes, not AAC
  vocabulary, so the Modified Fitzgerald colours meant nothing on them: every
  tile came out orange, and tiles that reused a library picture came out in
  whatever colour that word's category happened to be, so one menu printed in
  mixed colours. Menu tiles are now white on screen and in the PDF export, and
  generating a menu board no longer looks up a part of speech at all — which
  also removes a blocking AI call per menu item once a menu ran past its
  picture budget. Existing menu boards keep their current colours until they
  are regenerated.
- **The current-user payload now says whether a clinician application is
  pending.** `User#api_view` gained `clinician_application_status` — the status
  of the user's most recent `ClinicianApplication`, or `nil` if they never
  applied — so the app can show a "your application is under review" notice on
  the dashboard instead of leaving applicants with no sign that anything
  happened. Derived from the application record rather than a stored column:
  approval already flips `plan_type`, so "pending" is the only state the
  frontend couldn't otherwise see, and a denormalized copy would be one more
  thing to keep in sync with the admin review queue. A re-applicant reports
  their newest application, not the old denial.

- **A submitted Clinician application now pings an admin.** Every other inbound
  signal in the app emails one — new signup, feedback, playground nomination —
  but a SpeakAnyWay for Clinicians application only mailed the applicant, who
  was promised a review "within a few days", and then sat in
  `/admin/clinician_applications` until somebody happened to look.
  `AdminMailer.new_clinician_application_email` carries the applicant's name,
  email, credential, license/cert number and workplace plus a link straight to
  the pending queue, so the application can be triaged without opening the
  dashboard. It fires from an `after_create` on `ClinicianApplication` (the
  `FeedbackItem` pattern, so any future non-API creation path is covered too)
  and is rescued and logged — a mailer failure can never roll back the
  application the clinician just submitted.

- **A user on a trial can upgrade again.** Anyone on a Basic or Pro trial
  without a card on file got *"Something went wrong loading plan details"* every
  time they opened the plan-change modal, with no way forward but closing it.
  `preview_plan_change` was asking Stripe for an upcoming invoice, which Stripe
  refuses outright for a no-card trial ("the subscription will cancel at the end
  of the trial instead of generating an invoice") — and since Stripe does not
  prorate during a trial, there was never anything to ask for. Trials are now
  priced directly: $0 due today, the trial end date unchanged, the new price
  billed when the trial ends. No card is requested mid-trial. If Stripe cannot
  price a non-trial switch for any other reason, the modal now degrades to the
  plan name, price and next billing date and still lets you confirm, rather than
  failing. Plan-change errors also carry machine-readable codes, and Stripe
  failures are logged with the detail needed to diagnose them and reported to
  AppSignal instead of passing silently as an ordinary 400.

- **A communicator can now add a word to their own board.** `POST
  /api/boards/:id/add_image` accepted a user token only, so a nonspeaking user
  signed in as themselves got a 401 — which made the app's new Quick add button
  impossible on the one surface it matters most, the communicator's own
  dashboard. The endpoint now accepts either credential; everything it creates
  (the image, any uploaded picture) is attributed to the adult who owns the
  account, since a communicator owns no images of their own. A communicator may
  only add to a board that is actually on their dashboard — note this is a
  separate check from the plan lock, because `User#board_editable?` returns true
  for a board you do not own and so can never answer an ownership question.
  Every other board write stays user-only, and the user-token path is unchanged.

- **Copying a board now copies the pages its folder tiles open.** "Use this
  board" was a shallow copy — one board, one board slot — so every folder tile
  on the original arrived as a plain talking tile, and the notice explaining
  that ("17 tiles on the original opened extra pages…") was shown to everyone
  on every plan. It was never about the plan: any tile pointing at a board the
  copier didn't own was flattened, so someone with 299 free board slots got the
  same 17 flattened tiles as someone with none. Copying now takes the whole
  linked set, one board slot per board, and the client is told what that will
  cost before anything is created (`GET /api/boards/:id/clone_plan`). When the
  set is bigger than the remaining slots, the copy is partial rather than
  refused: the pages nearest the main board come across and only the tiles that
  opened the rest become talking tiles. The clone response now carries
  `boards_created`, `boards_in_set` and `limited_by` beside the existing
  `flattened_tiles`, so the app can say what actually happened and offer the
  upgrade path only when more slots would in fact have helped.
- **A MySpeak starter board brings its pages with it, and they are boards the
  parent can find.** The starter was already cloned into the parent's account,
  but only its root counted or appeared in the board list — its linked pages
  were minted as invisible templates, so a six-board starter cost exactly one
  slot and five of its pages could be reached only by tapping a folder tile,
  never opened from the board list to edit. Every page in a copied set is now a
  real board the parent owns, lists, and can edit, and the wizard's
  `starter_board` report says how many boards it created. Board assignment
  (putting a board on a communicator from the dashboard) is unchanged and still
  costs no board slots.

- **A board can be copied on its own, without its linked pages.** `POST
  /api/boards/:id/clone` takes `include_linked_boards: false`, which copies the
  root board and turns its folder tiles into talking tiles. A set someone has
  room for is still a set they may not want, and spending nine board slots to
  get one board shouldn't be the only option. Nothing is withheld on that path,
  so the response reports no `limited_by` and the app offers no upgrade for it.

### Fixed

- **A MySpeak page no longer shows a board that opens to nothing.** Adding a
  board that was already favorited on that communicator saved nothing, so the
  step that publishes it never ran — the card appeared on the public page and
  404'd when a visitor tapped it.
- **A board a parent already owns can no longer be added past a communicator's
  board cap.** The per-communicator limit was checked only when the wizard
  cloned a starter, so picking one of her own boards walked straight past it.

### Added

- **Board Builder templates are visible and manageable from the admin
  dashboard.** The seed material every built board set is cloned from — the Core
  60/84 vocabulary sets and the eleven fringe category pages — lived only in the
  database, reachable through a Rails console and a rake task. There was no way
  to tell whether a template was healthy, and a defect in one is a defect in
  every set built after it. `/admin/board_builder_templates` now lists all of it
  with a health report (stacked tiles, duplicates, missing pictures, grid size,
  and — for a fringe page — whether the builder can actually reach that category
  or is quietly paying for an AI-generated page instead), links straight into the
  board editor for tile work, and adds Repair, Re-seed and Export. A new fringe
  template is added by building the board under Board Builds and registering it
  against a category here.

  One thing the page is explicit about: re-seeding is a destructive sync against
  the authored files in the repo, so an edit made in the board editor is reverted
  by the next re-seed. Export downloads the board as its authored `.obf` so the
  change can be committed and made permanent.

### Changed

- **The "your trial is wrapping up" reminder now says what actually happens to
  your boards.** Three days out, the reminder knew your trial was ending but not
  what ending it would cost — so a parent who built a full board set during the
  trial found out which boards had gone read-only only after it happened. The
  reminder now carries that number, and the in-app banner says it too. Nothing
  is deleted and every board stays usable for communication; this is about not
  being surprised.

- **Going over your board limit no longer freezes everything but one board.**
  If your plan's boards are read-only — a lapsed trial, a downgrade — you now
  keep your five most recently used boards editable instead of a single one.
  This matters most after a trial: a set built with the Board Builder is
  20-plus boards, and being left with one editable board out of thirty made a
  fortnight's work unreachable. Nothing about your plan changed and nothing is
  deleted: every board stays fully usable for communication as always, and you
  still can't create new boards until you upgrade or make room.

- **One board limit, and the Board Builder counts against it.** Your plan used to
  carry two separate caps — one for boards and one for Board Sets — and the Board
  Builder only checked the second. So a user sitting at their board limit could
  run the wizard, receive a whole 20-plus board set, and still see "1 of 1
  boards" on their dashboard: the builder was gating on one number while the
  dashboard reported the other. There is one number now. Every board the builder
  creates counts, Board Sets themselves are no longer capped, and the wizard
  checks up front that the entire set will fit rather than starting a build it
  can't finish. Two things follow. On the Free plan a set no longer fits at all,
  so the Board Builder is a paid feature; and a Free account that already built a
  set is now over the limit, which means those boards become read-only — still
  fully usable for communication, just not editable until you upgrade or make
  room. Your plan's board limit also tracks your plan directly now, so a change
  to a tier reaches everyone on it instead of only new accounts.

- **Every new account now starts a 14-day free trial of Basic or Pro.** You pick
  a plan when you sign up and the trial starts immediately — no credit card, and
  no trip through a payment page, because there's nothing to charge during a
  trial. If the trial ends without a card on file nothing is deleted and nothing
  is charged: the account simply continues on the free tier, with over-limit
  boards read-only and over-limit communicators in fallback mode. Signups in the
  iOS and Android apps are unchanged and still start free, since the app stores
  require their own in-app purchases for subscriptions. Existing accounts are
  unaffected.

- **AI credits now arrive the moment you sign up.** Your welcome tokens and your
  plan's monthly AI credits used to wait until you clicked the link in the
  verification email — so a brand-new account that hadn't opened its email yet
  had a zero balance, couldn't generate a tile picture, and got its allowance
  zeroed again by the monthly refresh. Credits are granted at signup on every
  plan, the monthly refresh runs for verified and unverified accounts alike, and
  image generation no longer asks whether your email is verified. Verifying your
  email still matters — it's how we know we can reach you — it just doesn't hold
  your credits hostage. Accounts created under the old behavior get their
  credits on the next monthly refresh, and their welcome tokens the first time
  they verify.

### Fixed

- **Setting up a MySpeak page no longer quietly makes a second copy of a
  board.** If you'd already used your board slot, the MySpeak setup wizard
  cloned another board anyway — and that copy didn't show up in your board list,
  didn't count on your dashboard, and couldn't be opened or edited, even though
  it was the board your child's public page linked to. Edit "your" board and the
  page kept showing the copy. Now the wizard's board is an ordinary board of
  yours: it appears in your board list, counts toward your limit, and opens like
  any other. If you're already at your limit it doesn't create anything at all —
  it tells the app why, so you can point the page at a board you already have.
  You can also hand it a board you already own and it attaches that one instead
  of copying it. Boards already on a MySpeak page stay published, as before.

- **A brand-new account is greeted as new, and speak mode offers "Edit this
  board" again.** Two fields the app reads were missing from the API responses
  it reads them from, so shipped behavior never appeared: the current-user
  response carried no `created_at`, so a thirty-second-old account landed on the
  dashboard reading "Welcome back" with the plan-limit card the first-visit
  welcome exists to hide; and the board payload speak mode loads carried no
  `can_edit`, so a board's own owner saw a one-row ⋮ menu one screen after being
  told the board was theirs to edit. Both fields are now served, using the same
  ownership and read-only rules the rest of the app already applies.

- **An admin edit no longer silently turns off your display settings.** Changing
  anything on a user from the admin screen — a plan type, a limit — used to
  write "off" to the display preferences the form didn't send, so the picture
  strip above the board disappeared with nothing to say why. Those settings are
  now only changed when they're actually edited, and an admin can set "Show
  labels" and "Show tutorial" too.

- **A communicator's display settings now have a real default.** A communicator
  whose settings were never saved from a form carried no preference at all, so
  whether pictures showed above the board depended on which screen had created
  them. Communicators now start with the same defaults their owner's account
  has.
- **A 5-Year license can no longer be sold as a monthly subscription.** The
  subscription checkout endpoint now refuses `basic_5yr` / `pro_5yr` outright
  and points at the license endpoint, instead of relying on the key happening to
  be missing from its price map. Licenses also report their own billing interval
  (`five_year`) in analytics, so a license buyer is never counted as a monthly
  subscriber.

- **Copying someone else's board no longer leaves folder tiles that open their
  boards.** A copy has always been one board, but its folder tiles kept pointing
  at the original owner's pages — so they opened boards you don't own, and broke
  outright if that owner later unpublished or deleted one. Those tiles now become
  ordinary speaking tiles in your copy, and the app can tell you how many changed.
  Folder tiles that point at your *own* boards are untouched, and copying still
  uses one board slot.

- **Boards from the Board Builder are named correctly again.** Building a set
  could name the board — and its board set — after an unrelated admin board
  (for example "Classroom — Core Words Poster") instead of "Core 60" or
  "Core 84", and build it from that board's tiles rather than the intended
  starting vocabulary. All three sizes (Starter, Standard, Extended) are fixed.
  Boards already built keep whatever name they were given; rename them from the
  board's settings if you want to.

- **A word's default picture is no longer left ambiguous after duplicate images
  are merged.** Consolidating two library images that each had their own default
  picture left the survivor carrying both, so which one showed was arbitrary
  rather than chosen. Merging now settles on one, and
  `rake library_images:reconcile_defaults APPLY=1` repairs images merged before
  the fix without changing any picture that is currently showing.

### Added

- **A kit landing page can now hand over an editable Canva template.** Alongside
  (or instead of) a PDF, `/admin/kit_pages` takes Canva template links — paste
  the "Share → Template link" and a visitor gets their own copy of the design to
  edit, rather than a finished page to print. That is what makes a MySpeak ID
  card possible as a free download: the visitor adds their own name and photo,
  and uses Canva's QR Code app with their MySpeak link to put a working code on
  the card. The link is revealed after the email, exactly like the PDF, and a
  page may offer templates with no PDF at all. Both link shapes Canva hands out
  work — the full `canva.com/design/…` URL and the `canva.link/…` short link.
- **Your MySpeak link is now shown where you print things.** The Print & share
  section of a communicator's screen has a copy button for the permanent link —
  the address that keeps working even if you get a new public link, so it's the
  one to put on anything you print. The QR code screen now uses that same
  permanent address, so a code printed from it survives a link change.
- **You can now get a new link for a MySpeak page, and printed tags keep
  working.** If a page's link has been shared with someone who shouldn't still
  have it, "Get a new link" replaces it — and the old one stops working
  entirely, which is the point. Until now the link could never be changed, so a
  link that got out stayed out. The QR on a device tag, safety card, or care
  plan is unaffected: those now point at a separate permanent address that is
  assigned once and never changes, so revoking a link never means reprinting
  anything. Existing pages get their permanent address from
  `rake profiles:backfill_permanent_slugs` (previews by default).
- **A kit landing page can now give away a PDF you upload, not just a board
  printable.** `/admin/kit_pages` has a Document card: drop in one or more PDFs
  and they become the page's download, so a parent handout or a workshop packet
  can be a lead magnet without first being generated as a printable. Each file
  takes an optional label, which is the text on its download button when a page
  hands over more than one. While anything is uploaded there it is *the*
  download — the printable dropdown is ignored until you remove it. The first
  couple of pages of the PDF are rendered automatically as the pictures shown
  on the landing page.
- **Admins can now set the library's default picture for a word, and remove a
  picture from the library for good.** Both were previously only possible as a
  side effect of a user-shaped action. On the image edit screen there is now a
  "Library default picture" panel: pick which picture a word falls back to for
  everyone who hasn't chosen their own, or delete one outright — hidden ones
  included. Changing the default never repaints a picture someone already
  chose; it changes what empty tiles fall back to and what new tiles start with.
- **A safe way to condense duplicate library images.** The seeded library
  carries several rows for the same word, and when only one of them has art the
  others show up blank. `rake library_images:scan` now reports the duplicates
  and stores a reviewable plan without changing anything;
  `rake library_images:apply[ID]` merges them in the background, keeping every
  picture, every board, and every saved preference.

### Fixed

- **The admin page for a board printable no longer errors once one of its
  listings has an Etsy draft.** The "Send video" button on a listing card asked
  for confirm text that had been dropped when a printable gained the ability to
  carry several listings, so opening the printable failed outright — taking
  every listing on the page with it, not just that one button.

- **A built Core 84 set no longer gains a stray tile named after the core board,
  or an extra row.** Three things stacked up. The seeded Core 84 board had two
  tiles parked on the same cell (`all done` sitting on `again`), which hid one
  of them and made the full grid report a free cell it didn't have; re-seeding
  now pulls a tile like that back to its authored cell even when it carries no
  authored button id, and un-stacks anything left over. A folder tile pointing
  at another set's home board pulled that whole board into a build as an extra
  page — a second full core board, which the nav sync then gave a way-home tile
  labelled "Core 84"; the build now refuses to clone a board that is the top of
  a set. And a page whose grid is already full no longer gets a way-home tile
  at all: navigation never displaces vocabulary. `rake
  board_builder:repair_stray_core_pages` reports and repairs sets already built
  this way.

- **Printable PDFs are about half the size they were.** Every board page in a
  printable was rendered separately, so anything the pages shared — the header
  logo, the navigation row that repeats across a board set — got stored again
  on every single page. A ten-board set came to 17 MB, over 7 MB of which was
  the same handful of pictures over and over, and files that big were refused
  by Etsy. The merge now stores each picture once: a set that was 17 MB is
  9 MB, with every page and every pixel unchanged. If a printable is still too
  big to sell, the admin page says so as soon as it finishes generating,
  instead of at publish time.

- **Setting up a MySpeak page no longer dead-ends when you already added a
  communicator.** On the Free plan you get one communicator, and adding one
  from the dashboard quietly created its MySpeak page too — blank. The setup
  wizard could only make a *new* communicator, so it refused you at the very
  last step, after the name, the photo, the contacts and the emergency notes,
  with "Sandbox communicator limit reached." It now fills in the page you
  already have instead. If several of your communicators have a page that was
  never set up, it asks which one rather than guessing. A page anyone has
  actually written on is never touched, and adopting a page gives it a fresh
  unguessable link, the same as a page made from scratch.

- **Making someone a Partner from the admin page now actually sticks.** Changing
  a user's plan to `partner_pro` on `/admin/users/:id` moves their Stripe
  subscription onto the Partner Pro price — or creates a no-card trial
  subscription if they don't have one — instead of leaving it on whatever plan
  they were on before. Previously the change only landed locally for anyone who
  already had a subscription, and the next routine update from Stripe quietly
  put them back on their old plan. The admin is now told exactly what happened
  in Stripe (including if it failed, so it can be re-run), and the user page
  shows the subscription's live status and price with a warning when it isn't
  the Partner Pro one. Extra communicator add-ons a user bought are carried
  across untouched. Note that swapping someone who is actively paying forfeits
  the unused part of what they already paid — Stripe issues no credit — so the
  page warns before the switch. As a backstop, a Partner is no longer demoted by
  their own subscription's updates even if the Stripe change didn't land.
- **A communicator added from the dashboard now gets an unguessable MySpeak
  page address, the same as one made in the MySpeak wizard.** Adding "River
  Stone" produced the public page `/my/river-stone` — derivable from the
  child's name by anyone — while the wizard produced `/my/s-k8x2mf`. Nothing
  re-addresses a page afterwards, so emergency information filled in later sat
  behind the guessable link. New communicator pages now always get the random
  address. Existing pages are unchanged until you run
  `rake profiles:migrate_to_random_slugs`, which previews by default, keeps the
  old address working as a redirect, and re-sends updated device tags for the
  pages it moves. A communicator page's random address can't be edited (that
  is the point of it), and trying now explains why instead of showing "You can
  change your link again on ." with no date.

- **"Make this my editable board" no longer reports success while changing
  nothing.** `PATCH /api/boards/:id/make_editable` wrote `editable_board_id`
  and always answered 200, but the read-only gate resolves the edit slot
  through its own rules and ignored the pick in two cases: an owned board with
  `is_template: true` (the `boards` association filters those out, so the
  designation never resolved), and any plan whose `board_limit` is above 1
  (Clinician, or an account whose limit was raised), where the editable set was
  chosen purely by recency. Both left the board locked with the API reporting
  success, which the frontend showed as nothing happening at all. The endpoint
  now verifies the board really became editable, rolls the write back and
  returns `editable_board_not_available` (422) when it didn't, and a
  higher-limit plan pins the designated board ahead of its recency-ordered
  slots.
- **MySpeak pages are free on every plan again.** Adding a communicator quietly
  created their MySpeak page for you — and that page was counted against a
  separate one-per-account limit, so on the Free plan your very first
  communicator used up the only slot. The next time you tried to make a page you
  were told "only one allowed per account," for a page you never knowingly
  created. Every communicator gets a MySpeak page on every plan now, exactly as
  the rest of the app says; how many communicators you can have is the only
  limit. Your own public page is separate and unaffected.
- **Deleting a picture from an image no longer deletes it permanently by
  mistake.** "Remove" was documented as a hide you could undo, but every remove
  destroyed the file for good.
- **A picture you saved from an image search no longer changes what everyone
  else's new tiles start with.** Saving art onto a shared library word moved the
  library-wide default even when you weren't the one who owns it.
- **Word suggestions now match what the board is actually about.** Asking a
  board to suggest more words used to give very different results depending on
  whether you had touched the "prompt override" box — a board called "Places"
  came back with "different", "again", "something else" and "all done" if you
  left the box alone, but with real places the moment you typed anything
  different into it. Both now take the same path, so the suggestions match the
  board whether you customise the prompt or not. Suggestions for a topic page
  are also free to name things again: a page of places, foods or people is
  supposed to be full of nouns. Words like "stop" and "all done" are still
  suggested for a board that hasn't got a way to say no yet — just not for one
  that already has.
- **Free kit downloads now actually download.** The Download button on a
  `/kit/...` landing page used to open the PDF in the browser's viewer instead
  of saving it — a long wait on a blank tab for a big printable, and then you
  still had to find the viewer's own save button. Each file is now served with
  a second, signed link that tells the browser to save it, alongside the
  original link for anyone who'd rather preview it first.
- **"Format with AI" lays boards out cleanly again.** It no longer makes two
  tiles double-width — every tile is one cell, so a board stops ending on a
  ragged half-empty row, and a board set to "no scrolling" keeps fitting the
  screen instead of quietly starting to scroll. Tiles are also grouped by
  Modified Fitzgerald category now, so the colours read as blocks (pronouns and
  quick words first, nouns last) rather than as confetti, and word pairs like
  up/down and hot/cold stay side by side.
- **"Format with AI" no longer scatters a board set's navigation row.** On a
  board built with the Board Builder — or imported as an OBF/OBZ set —
  formatting the board used to move the bottom navigation strip, including the
  small words at its ends, out into the middle of the board. The strip is the
  same on every page of a set on purpose, so a communicator can learn where a
  category lives; formatting one page broke that. The navigation row now stays
  exactly where it is and the words are rearranged around it, on tablets and
  phones too.

### Added

- **Every care plan now has a preview picture.** Each document is generated
  with a PNG thumbnail of itself, served alongside the download URL on the
  communicator payload, so the Print & share tab can show what a plan looks
  like at the size you picked rather than just a Download button. The
  thumbnail is rendered from the same HTML as the PDF and shares its freshness
  signature, so it can never show a document you no longer have; on the full
  sheet, which flows to as many pages as it needs, the picture is page one.
- **Care & routines: add your own chip to any preset row.** The preset lists
  ("AAC device", "Toilet training") are deliberately short, so a parent whose
  answer isn't on the list can now type their own and it becomes a chip on the
  same row — shown on the care card and printed on the care plan like any other.
- **Communication, Personal care and Moving around gained an "Anything else
  worth knowing" field**, so every care section now has one place for a
  sentence. Meals, Sensory and Getting around already had theirs.

- **The Care & Emergency Plan can be downloaded as a half-page fold card or a
  wallet fold strip, not just the full Letter sheet.** `POST
  /api/profiles/:id/care_plan` takes a new `size` param (`sheet` default,
  `half`, or `wallet`); `half` is one Letter page folded once, `wallet` is
  four cut-and-fold strips per Letter page, and both print single-sided. The
  care-only variant is offered at `sheet` and `half` but not `wallet` — a
  wallet card with no emergency block isn't worth the paper. Both fold sizes
  put one subject on each face: who this is and who to call on the front,
  day-to-day support on the back, so nothing is printed twice and neither
  face folds down half-empty.

### Changed

- **Board Builder pages are full pages now.** Every category page in the Core 60
  and Core 84 starter sets — People, Feelings, Food, Drinks, Play, Places, Body,
  School, Time, Describe — was carrying about twenty words in a sixty- or
  eighty-four-cell grid, so it opened mostly empty next to a home board that
  fills every cell. Core 60 pages now hold 40 words, Core 84 pages 60, and the
  eleven interest pages (Animals, Sports, Music, Bathroom, Clothing and the
  rest) 40 apiece, laid out in whole rows from the top. The Core 84 page for a
  category is a superset of the Core 60 one and keeps each word in the same
  block, so moving up a set widens the vocabulary instead of moving it around.
  The "More" page stays deliberately roomier — it is where extra pages a build
  adds are tucked away.

### Fixed

- **Board Builder pages no longer show "this" and "that" twice.** The strip
  along the bottom of every page carries those two words at its ends, and the
  build was re-adding them instead of recognising the ones already there — so
  each page ended up with a duplicate pair, and the copy sitting in the strip
  was the one that had gone silent. Existing sets are repaired by
  `rake board_builder:sync_nav_rows`.

- **The Safety ID card is no longer offered.** It printed the same allergies,
  medical needs, medications and emergency contacts as the Care & Emergency
  Plan's front page, so once that plan gained a wallet size — the same
  information on something you can actually clip to a bag — the card was a
  second copy competing with it. Cards already generated still exist and the
  endpoint can still build one; nothing is built unprompted any more. A side
  effect: saving a communicator's page (an avatar, a theme change) now runs two
  headless-Chrome renders instead of four, so it finishes noticeably sooner.
- **The per-section "Anything else worth knowing" detail lines are no longer
  offered on the built-in care sections** — custom chips cover the short
  answers, the new sentence field covers the rest, and "Your own sections" is
  still there for anything that genuinely wants a label and a value. Lines
  already saved are kept: they still show on the card and the printed plan, and
  the editor still lets you edit or clear them.

- **The care plan PDF has a new look.** Field labels sit on their own line in
  small caps above their value instead of inline with it; a picked
  (multi-select) answer renders as one chip per value, tinted to its
  section's colour, instead of a comma-joined sentence; each day-to-day
  section gets its own colour and icon; the header is a cream identity card
  with a gradient hairline instead of a full gradient band; the emergency
  block is a white card with a red left rail instead of a red-filled box; and
  a new "At a glance" strip (allergies and how the communicator talks) sits
  above it. Existing downloads keep serving the old look until regenerated.

- **The line under the communicator's name is now yours to write, or to turn
  off.** It used to be assembled from the communication section ("I communicate
  using AAC device and gestures. Keep my device close."), which repeated the
  "How I talk" cell in the At a glance strip just below it. It defaults to
  "I communicate differently. Please be kind & give me time.", and `POST
  /api/profiles/:id/care_plan` takes `subheader` (your own words, up to 160
  characters) and `include_subheader=false` (no line at all). Both are
  per-download choices — nothing is saved to the profile — and both ride the
  document's freshness signature, so changing either regenerates the PDF. A
  client that sends neither keeps the default line. It prints on the sheet and
  half sizes; the wallet card has no room for it.

- **Text tiles render once and are reused.** A text-tile picture is fully
  determined by its settings, so identical renders now share one rendered image
  instead of each forking headless Chrome and uploading its own copy — the same
  word on the same coloured tile is rendered the first time and reused after
  that. The bulk "Set text image" action also queues one job for the whole
  selection rather than one per tile, so selecting thirty tiles no longer parks
  everyone else's single-tile render behind thirty renders.

- **Etsy listing copy leads with the terms buyers search.** Generated tags are
  now always phrases — `aac`, `printable`, `slp`, `classroom` and `nonspeaking`
  were burning five of every listing's thirteen slots and don't rank, so
  single-word tags are refused outright and the pools were rebuilt around
  `printable aac`, `communication board`, `low tech aac`, `slp resources`,
  `classroom visuals`, `pecs alternative` and `nonverbal child`. Titles now lead
  with the product phrase and make the board name the qualifier
  ("AAC Communication Board Printable, Recess …" rather than "Recess AAC …"),
  except where the board name already names the product, which folds into the
  head ("AAC Core Words Board"). The admin printable page gained an advisory
  panel for unused tag slots, leftover single-word tags, and a title that buries
  the head term. Applies to newly generated copy only — existing listings are
  untouched until regenerated.

### Added

- **A tile can be pointed at an existing board as it is created.**
  `POST /api/boards/:id/add_image` now accepts an optional `predictive_board_id`
  and links the tile it creates in the same request, so the frontend's new
  "Link a board" tab never leaves a half-made unlinked tile behind. The id is
  resolved against the caller's own boards plus the public library — anything
  else is ignored and the tile arrives unlinked rather than erroring — and a
  self-link is dropped, since the API already renders those as ordinary tiles.
  The tile is marked `mute_name`, which is what makes it count as a folder tile
  in the board-set map, and falls back to the linked board's cover picture when
  its own image has no art.

- **Care plan downloads can be narrowed to the sections you want.** The care
  plan endpoint takes a `sections` allowlist, so a sheet for a bus driver
  doesn't have to carry the meals and personal-care pages. Sending no
  `sections` still prints everything, as before.

### Changed

- **The care plan PDF leads with the communicator's name.** The "SpeakAnyWay"
  eyebrow above it is gone — on a sheet whose job is to introduce one person,
  the brand was the first thing a reader saw. The mark still signs the footnote
  on every page.

### Changed

- **Word suggestions now get the same AAC brief the Board Builder gets.** The
  rules that decide whether a word earns a place on a board — favour words that
  finish many different sentences, every board needs a way to object and a way
  to redirect, no filler runs of colours or days of the week, no near-duplicates
  — were written for the admin board builder and only ever reached it. Every
  suggestion a parent or therapist can trigger ("suggest words for this board",
  "add more words", the scenario builder, interest pages) was asking for a
  topical vocabulary list instead, which is the thing those rules exist to
  prevent: a board full of correct words you cannot say anything with. All of
  them now share one brief, and the reply shape is pinned rather than described,
  so a malformed answer is refused instead of silently half-read.

### Fixed

- **AI board layout can produce the AAC colours again.** "Format with AI"
  asked the model for parts of speech from a list that did not match the app's
  own — it offered "interjection", "phrase" and "other", and left out
  `social`, `question` and `important_function` entirely. Since the colour
  resolver answers grey for anything it does not recognise, an AI-laid-out
  board could never render a red (no / stop), pink (please / yes) or purple
  (what / where) tile, which is most of the point of the Modified Fitzgerald
  Key. The prompt now asks for the app's real categories and anything outside
  them is discarded rather than quietly painted grey.
- **Choosing a layout with AI no longer changes other people's boards.** The
  part of speech the model guessed was written back to the shared picture
  library, so one person's layout run could recolour the same word on
  unrelated accounts' boards. The tile keeps its own answer; the shared row is
  left alone.
- **Scenario word lists are no longer cut short.** The request for a list of
  words capped the reply at a length that truncated it mid-list, and read the
  result as plain text, so a conversational opening line ("Sure! Here are 12
  words:") could be turned into the first word on the board.

- **The "Download updated cards" button in the safety-cards email goes to a
  real page.** It pointed at `/communicators/:id/safety`, a path the app has no
  route or redirect for, so parents told to reprint their child's safety ID
  card and device tag landed on a 404. It now opens the Print & share section
  of the communicator's MySpeak tab, where those cards actually live.

- **Detaching a printable from an Etsy draft no longer loses the draft.**
  "Detach & relist" used to forget the listing id, so the superseded draft was
  left in the shop with nothing naming it. Detaching now keeps the listing on
  record — its card stays visible, still showing which draft to go and delete —
  and a listing that reached Etsy can't be removed from the admin at all. A
  publish whose images or files fail partway also keeps its listing id now, and
  says the draft exists but is incomplete, instead of leaving an unnamed
  half-built listing behind.

- **The same listing video can go to two listings.** Etsy allows one video per
  listing, but the "already sent" record was kept per printable, so a second
  listing was refused a clip it had never received. It is now kept per listing.


- **Deleting a demo account from the admin dashboard works again.** Selecting
  demo accounts and pressing **Delete selected** reported "Skipped 1 selected
  user(s) that weren't demo accounts" and deleted nothing. The check treated an
  account with no role set — which is every ordinary signup — as failing the
  "not an admin" test, so every real demo account was skipped. The same skip
  applied to Mission Control's demo cleanup and to the JSON admin API's bulk
  delete; all three now agree with the checkbox the dashboard shows.

- **Changing a picture in the shared image library no longer repaints boards
  that already exist.** Pictures are shared: one "apple" image sits on
  thousands of boards across unrelated accounts. Picking a different picture
  for one of them used to rewrite that tile on **every** board, in every
  account — including tiles whose owner had chosen their own picture on a
  previous visit, and tiles where "Hide pictures" had deliberately switched the
  picture off. A library change now sets the picture for boards made *from now
  on*, and updates existing tiles only on boards you own. Your own picture
  picks are yours: marking a picture as your favourite no longer changes what
  anyone else sees. Boards can still be brought up to date with the newest
  library art on demand, one board at a time.

- **Imported boards show up on the boards page like any other board.** A board
  set imported from a `.obf`/`.obz` file was filtered out of board search and
  out of the public board library, so the only way back to it was the group it
  came in with. Imports now behave like everything else: the set's home board
  appears under the "Main Boards" filter and in search, and its interior pages
  sit under it as sub-boards instead of burying the rest of the list. Existing
  imports are settled by `bin/rails obf_import:classify_sets`.

### Added

- **A board printable can be sold as several Etsy listings.** One printable now
  carries a list of listings instead of a single one, so the same document can
  go up as a standalone listing and as a bundle side by side. Each listing gets
  its own title, tags and price, its own choice of gallery slides, its own
  subset of the download PDFs, and its own listing video — anything left blank
  falls back to the printable's. Add one from the printable's Etsy card, edit
  its copy, then create its draft; drafts still never go live from here.


- **The admin Users table shows where each account signed up.** A new **Source**
  column badges every user as iOS, Android, web, or unknown (accounts created
  before signup source was recorded), sortable like the other columns and
  filterable from the same dropdown as plans and demo accounts. The user detail
  page gains **Signup source** and **Signup method** alongside the existing
  signup ref.

- **The admin nav is shorter.** Board Builds, Board Printables, and Kit Pages
  now sit together under a single **Content** menu instead of each taking a slot
  in a bar that had run out of room.

- **Kit landing pages write themselves.** Creating a `/kit/<slug>` lead-magnet
  page used to mean typing a slug, headline, subhead, call to action and a raw
  JSON blob by hand. Pick the printable it gives away, press **Autofill the
  page**, and all of it is written from that printable. It only fills what's
  blank, so anything already typed survives, and nothing is saved until the
  usual Save.
- **Kit landing pages show the printable.** The mockup images already rendered
  for a printable's marketplace gallery — the printed sheet on a desk, the
  flip-book, the pages open on a tablet — now appear on its free landing page.
  The download itself still stays behind the email form.
- **Turn a whole selection into text tiles at once.** The board editor's bulk
  actions can now render every selected tile's own word as its picture, in one
  step, instead of opening each tile in turn. Free — no AI credits. Tiles with
  no word are left alone, as is any tile already showing that exact picture.

### Fixed

- **Renaming a board no longer changes its share link.** A board's URL
  (`/pb/<slug>`) used to be re-derived from the name on every rename, so
  renaming an unpublished board quietly broke any link already shared for it.
  The URL is now set when the board is created and stays put. Admins can still
  change it by hand, or ask for a fresh one from the current name.
- **Copied boards get a clean URL.** Duplicating a board names it "<name> Copy",
  and that "Copy" was ending up in the board's URL. Copy markers are now
  stripped from both ends of the name — "Copy of Snack Time" and "Snack Time
  Copy" both produce `snack-time`. Honest names survive: "Photocopy Board" is
  left alone.

- **Ampersands in Care & routines save properly.** Typing "&" into any care
  field — a sensory note, a meal detail line, a custom section title — stored it
  as the raw text `&amp;`, so the public MySpeak page and the printed care plan
  both showed that instead of the character. Existing entries can be repaired
  with `rake care:unescape_text DRY_RUN=false`.
- **Pasting a word list makes exactly those tiles.** Building a board from a
  pasted word list quietly appended extra AI-generated words to the end, and
  "Start with an empty board" came back full of them. Both happened because the
  board's own name was being used as an AI topic whenever no topic was typed.
  Words are now generated only when you ask for them — a situation in the story
  field, or the "Generate words" button.
- **No more duplicate tiles from mixed capitalization.** A word list containing
  both "Dog" and "dog" produced two tiles showing the same picture.

- **Menu boards keep their menu photo.** Renaming a board built from a menu —
  or changing its color, or saving its words — used to disconnect it from the
  menu it was made from, so the "View Menu" button vanished from the board page
  and never came back. Saving a board no longer touches where it came from.
  Boards already disconnected can be reconnected with `rake menu_boards:relink`.
### Changed

- **Etsy listing galleries now lead with a photo of the printable in use.**
  A board printable's gallery gains four photoreal mockups — the printed sheet
  staged in two rooms (a classroom easel, a kid table with crayons, a fridge
  door, a therapy clipboard, a binder) and the board running in the app on two
  tablets. The room and the tablet are picked from the board, so no two
  listings look alike. Rank 1 — the image that competes in Etsy's search grid —
  is now one of those photos rather than flat board art. Two slides made room
  for them: "how it works" duplicated the assemble steps, and the separate
  low-ink slide is now a single pale page inset into "what's included". The
  gallery fills Etsy's ten-photo cap exactly, and nothing needs adding by hand
  in the seller UI any more. Existing printables show a "rendered with an older
  gallery" badge in the admin until regenerated.
- **The trim-ready pages print bigger.** That variant exists so the board fills
  the sheet, but it was still reserving 20mm for a QR code — about 15% of the
  board's printed area on a landscape page, for a code small enough that phones
  struggled with it anyway. The band is now one thin line naming the board's
  web address, and the board takes the space back. The scannable code is
  unchanged on the full-colour and low-ink pages and on the cover.
- **Etsy listing QRs are tagged for attribution.** The QR in a printable's
  gallery images and listing video now carries `utm_source=etsy` campaign tags,
  so traffic from a listing is identifiable in analytics. The QR **printed into
  the PDF** deliberately stays untagged — the longer URL makes a denser code
  than the printed size can carry, and a code that won't scan costs more than
  the attribution is worth.
- **The listing video's closing frame reads on two lines.** "Free audio
  companion. / No app, no sign-in." no longer wraps mid-phrase.

### Added

- **Free-kit landing pages can be built without a deploy.** A new admin screen
  (`/admin/kit_pages`) creates a lead-magnet page served at `/kit/<slug>`: its
  headline, blurb, "what's inside" list and call to action are edited in the
  admin, and the download is one of your existing board printables. A visitor
  enters an email and gets the PDF; the email lands in Mailchimp under a tag
  named for the page, so each campaign is its own segment. Pages start as
  drafts and go live when you publish them. `/classroom` and `/ctg` are
  untouched — they're printed on QR codes and keep working exactly as before.
  Picking a printable that's for sale on Etsy is refused until you tick a
  separate "give this away for free anyway" box, which records who chose it.

- **A printable's topic can be edited after it's created, and the listing copy
  rebuilt from it.** The topic is the only part of a listing that describes the
  product — without one, the generic tag pools fill all 13 of Etsy's slots and
  every listing ships the same tags. It used to be settable only when the
  printable was created. It now sits on the listing form, with a
  "Regenerate from topic" action that rebuilds the title, summary, description
  and tags (keeping the price). Nothing is sent to any marketplace.

- **A listing video can be sent to a listing that already exists.** Publishing
  carries the video with it, so a listing created before its video was rendered
  could never get one without relisting. The video card now offers "Send video
  to the listing" for a printable already attached to one. It only ADDS a video
  — Etsy allows one per listing and the app can't read a listing back to check,
  so the control retires itself once a clip has gone and points at the Etsy
  seller UI for a swap.

- **Two admin backfill tasks for listings made before the current gallery and
  video.** `rake printables:render_listing_videos` queues a flip-through for
  every printable with no video or a stale one (`PUBLISHED_ONLY=1` narrows to
  listed ones), and `rake 'printables:export_listing[<id>]'` writes a
  printable's copy and gallery images to disk with a `listing.json` for the
  `speakanyway-printables` Etsy CLI, so a live listing's tags and photos can be
  replaced without relisting it.

- **A published printable can be relisted.** The app only ever creates Etsy
  listings — it has no way to update one — so re-rendering a gallery or a video
  could never reach a draft that already existed. "Detach & relist" on the Etsy
  card releases the link so Publish makes a fresh draft with the current images
  and video. Nothing is sent to Etsy; the old draft is yours to delete. The
  boards the printable protects stay protected.

- **The credits endpoint now reports your actual monthly allowance.**
  `GET /api/me/credits` returns a `plan_allowance` field alongside the existing
  balances, taken from the amount you were really granted this period rather
  than a per-plan constant — so a plan whose allowance was set individually
  reports the number you were given. The app uses it as the denominator for
  "N of 400 left" on the dashboard.
- **Etsy listings now carry a video.** A printable's listing gets a
  flip-through: an intro card, each printed page in turn with the "back button
  on every page" marker, and a closing frame with the QR beside the same board
  open in the app. Rendered from the admin ahead of publishing, 1080×1080 and
  5–15 seconds so Etsy accepts it, and uploaded with the draft. A hand-made
  clip can be uploaded instead for the listings worth filming.
- **Three new gallery slides, and a hero that shows a bundle is a bundle.** The
  gallery goes from six images to nine. The new second image is the one that
  says what these products actually are — a flip book of linked pages, where
  folder tiles open a page and every page has a way back. There is also a
  print-and-bind slide and a full page index, and the hero now carries a bundle
  count and fans up to five pages instead of three.
- **Listings are staged on photographs of real tablets** rather than a drawn
  one, with the board warped onto the glass in perspective.

- **Imported boards keep their tile sizes.** OBF/OBZ import used to force every
  tile to a single cell, so a board whose file described wide tiles — a
  point-to-talk board with a 13-column alphabet strip under word tiles spanning
  three or four columns — arrived as a uniform grid with gaps, and every tile
  had to be resized by hand. Import now reads the size the file describes,
  either from a button repeated across the cells it covers or from explicit
  `ext_speakanyway_w` / `ext_speakanyway_h` fields. Files that say nothing about
  size import exactly as before.
- **A communicator's public MySpeak page now says whether they can sign in.**
  The public payload carries a `sign_in_available` boolean so the page can offer
  a "Sign in as {name}" shortcut to the person it belongs to, instead of leaving
  them to find the communicator sign-in screen on their own. It is false for
  sandbox communicators, for anyone in fallback mode after a downgrade, for Free
  plans, and for accounts with no passcode set — all cases where signing in would
  dead-end — so the shortcut simply doesn't appear. No passcode, email, or token
  is exposed.

- **Boards that are sold as printables are now protected from accidental
  changes.** Once a printable reaches Etsy, the boards it was built from — the
  whole set, not just the first page — can no longer be deleted, unpublished or
  renamed, and editing their tiles asks for a confirmation first. Printed copies
  carry a QR code pointing at each page, and paper can't be re-issued, so a
  rename or an unpublish would quietly 404 a sheet already in someone's hands.
  The admin shows which boards are frozen and by which listing, and has a
  deliberate "Release protection" button for when a product really is retired.

- **Printables now tell buyers how to keep their own copy.** The about page and
  the how-to-use page explain that a shared board can change or move over time,
  and that making a free account and saving your own copy keeps the exact set of
  words in this print. Nothing about the boards themselves changed.

- **Generated marketplace copy now describes the printable it belongs to.**
  Every listing used to open with the same sentence and carry the same 13 tags,
  so a hospital-stay board and a hair-salon board were indistinguishable in
  search and competed with each other instead of reaching buyers. The topical
  keywords now lead the tag list, they are mined from the board's own page names
  when no topic is typed, and the opening line names the subject. The admin page
  also warns when a printable's tags overlap heavily with another's, naming the
  listing it collides with and the tags they share.

- **A board builder page can reuse a board you've already published instead of
  drafting a new one.** Most sets want a "Feelings" page, and the AI cheerfully
  invented a slightly worse one every time. When a page's name matches a
  published board of yours, the page now offers to link that board instead —
  the folder tile opens it exactly as it is, and creating a fresh page stays the
  default. A linked board is never touched by the build that points at it:
  publishing, unpublishing or deleting the set leaves it alone. It keeps
  whatever "back" tile it already had, so it has no way back to the new main
  board — the review screen says so before you build. (Admin only.)

- **Pick a different picture for any tile on the board builder's review
  screen.** The library often has more than one symbol for a word, and until now
  the only way to reject the one it picked was to ask the AI for a brand new
  one. Every tile with alternatives now carries a small picture chooser next to
  its "regenerate with AI" box — choose one and the preview updates on the spot;
  the board is built with exactly that picture. The choice applies to that board
  only: nothing changes for anyone else using the same word, and nothing is
  written until you press Build. (Admin only.)

### Changed

- **A board made from a menu photo now fits its own grid.** Menu boards were
  always built eight tiles wide no matter what the photo held, so a six-item
  café menu arrived as one long strip and a forty-item diner menu as a wide
  block with a ragged last row. The grid is now sized from the number of items
  actually found on the menu, squaring up whenever the count allows it — nine
  items land 3×3, sixteen land 4×4, twenty-five land 5×5 — and a very long menu
  gets taller rather than squeezing tiles too small to hit on a tablet. The
  board also now reports the same width it is drawn at; the two had drifted
  apart (laid out at eight columns, described as six).
- **AI board drafts now come back laid out, not just filled in.** The order the
  AI answers in is the order the tiles land on the grid, so a scrambled word list
  was a scrambled board: a verb, a noun, a pronoun, another noun, and the
  colour-coding that is supposed to help a communicator find a word reading as
  confetti. Drafts are now grouped before they reach the form — the quick words
  (I, you, yes, more, no, stop) in the opening cells, then verbs, then describing
  words, then the topic words, with folder tiles and every "back" tile on the
  bottom rows where the rest of the app keeps navigation. Words a model reliably
  miscolours are corrected on the way ("stop" is a protest word, not an action
  word), and the drafted list is still ordinary text you can edit — nothing is
  re-sorted once you have touched it. (Admin only.)

- **Better words on AI drafts.** The drafting prompts now ask for what makes a
  board sayable rather than accurate: words that finish many sentences instead of
  one, a way to object and a way to redirect on every board, no nouns that exist
  only to be labelled, no days-of-the-week filler, and a register that matches
  who the board is for. Folder pages are asked for the verbs and describing words
  that belong to them, not just the things you would find there. (Admin only.)

- **Words drafted with AI now come back lowercase, the way AAC tiles are
  written.** "Draft with AI" and "Draft the whole set with AI" were handing back
  Title Case — "Apple", "All Done" — and that casing followed the words all the
  way onto the built board. Words are now lowercased, while genuine capitals are
  kept: proper nouns and brand names, words like "iPad" and "TV", the pronoun
  "I", and folder tiles, which stay capitalized on purpose so a page you open
  reads differently from a word you speak. Words you type yourself are never
  changed.
- **Better suggestions from "Draft the whole set with AI".** The main board now
  starts from the same core-word spine a single board gets, every board aims for
  a balance of verbs and function words rather than a wall of nouns, and pages
  are asked for as places and routines ("Snack Time", "Going Home") instead of
  categories of things ("Equipment", "Colors"). A page no longer repeats a word
  the main board already carries, and a board that comes back well short of its
  tile count is topped up automatically instead of leaving you to type the rest.
  Drafting also runs on a stronger model. (Admin only.)

### Fixed

- **The communicator page loads quickly again.** Opening a communicator could
  hang for over 12 seconds for anyone with a large board library — the page
  rebuilt a picture-and-word preview for every board the owner had, one
  database round trip at a time, so the wait grew with the size of the library
  rather than with anything on screen. The page now gathers those previews in a
  fixed number of queries, so it opens at the same speed whether the owner has
  ten boards or a thousand. The "recently used" strip is also fixed: on a board
  shared with other people it could show activity that wasn't this
  communicator's.

- **Boards on a communicator's MySpeak page now actually open.** A board put on
  a communicator's public page showed up in the grid, but tapping it gave a
  "board not found" page unless the board had separately been published — and
  boards made by the Board Builder, or picked during MySpeak setup, start out
  unpublished, so this was the normal case rather than a rare one. Adding a
  board to a communicator now publishes it, along with every page in its set, so
  folder tiles work too. Removing a board from the page never unpublishes it, so
  a link already printed on a QR tag or in an IEP keeps working. A board someone
  else owns — an SLP's shared board — is left alone rather than being published
  on their behalf; it simply doesn't appear on the public page. Any board that
  isn't published is now hidden from the grid instead of showing a card that
  leads nowhere.

- **A printable's listing video is no longer destroyed by "Regenerate".** The
  code that decides which attachments are buyer downloads treated anything that
  wasn't a gallery image as a PDF, so a video counted as one — and the cleanup
  that removes superseded PDFs deleted it silently on every regeneration. It
  could also have been handed to a buyer as a download.
- **Boards assigned to a communicator now get their own cover picture.** A board
  put on a communicator is copied rather than shared, and the copy's cover was
  never drawn — so a communicator's dashboard, and the board grid on their public
  MySpeak page, showed a grid of grey "Board thumbnail" placeholders instead of
  pictures. Someone opening a MySpeak page from a QR tag had no way to tell the
  boards apart at a glance. New copies render their cover on assignment, and
  `rake board_covers:render_missing` draws the missing ones for boards assigned
  before this fix. A copy also no longer borrows the original board's cover
  picture, which could show the wrong board under the right name.

- **Tiles no longer end up silently missing their own audio.** When a board's
  voice was set while its tiles were still being written, the job that fills in
  each tile's audio could run before those tiles existed. It didn't fail — it
  quietly skipped them, so the audio file was made but never attached to the
  tile. A tile left that way stayed mute on every load and had no way to
  recover. The audio work now waits until the tiles are actually saved. A
  repair task (`tile_audio:backfill`) fixes tiles already affected, reusing
  audio that was already generated wherever possible.

- **A MySpeak page with an "About me" but no intro now gets its spoken audio.**
  The recording step bailed out whenever the intro was empty, and it did so
  before deciding which field it was working on — so the About me audio was
  skipped too. The public page then had to generate speech from scratch on
  every tap of "Read aloud", which is what made the button feel slow. Each
  field is now recorded on its own.

- **Audio and images are served with caching headers.** Files went out telling
  browsers nothing about how long they could be kept, so the same unchanging
  clip was downloaded again every time it played. New uploads now carry a
  long-lived caching header; `rake audio:backfill_cache_control APPLY=1`
  applies it to files already stored.

- **The transient image-processing error that killed background jobs is fixed
  at the source.** Building a board set, importing an OBF file, or saving newly
  generated art could resize a tile picture in the middle of a database
  transaction. The resized file was cleaned up before it could be uploaded, so
  the job died at the very end — after all the work was done — and whatever it
  was in the middle of stopped there. Tile pictures are now resized outside the
  transaction, or queued to be resized the moment it finishes. Nothing is lost
  in the meantime — the tile shows its full-size picture, which looks the same,
  just weighs more.

- **A board build that finished writing its boards is no longer reported as
  failed.** The builder created the whole set, published it and got it right,
  then hit a transient image-processing error on the way out — and the build
  page painted the lot red, which read as "this produced nothing, build it
  again". It now says the boards are fine and only the finishing step didn't
  run, with a "Finish build" button that completes it. That step matters
  beyond the badge: it's what queues AI art for tiles the symbol library had no
  picture for, so those tiles used to stay blank forever. Retries can repair a
  build now instead of skipping it, and a build is never rebuilt on top of a
  set it already created. (Admin only.)

- **Regenerating a board printable now actually gives you the updated PDF.**
  Editing a board and pressing Regenerate rebuilt the document correctly, but
  the download kept handing back the old one — the new file was uploaded to the
  same storage path, and the CDN in front of it goes on serving whatever it
  cached there. Each run now writes to its own path, so the download is the
  version you just generated. The file keeps its name, and the previous copy is
  cleaned up once the new one is safely in place. (Admin only.)
- **Boards built from the admin dashboard now get their covers.** Every page of
  a built set queued its cover render before the set had finished saving, so the
  render went looking for a board that wasn't there yet and failed — one dead job
  per page, and a set that could sit on "Still building your cover" for good if
  the retries ran out too. Renders are now queued once the whole set is safely
  written. (Admin only.)

- **The board builder's AI draft buttons work again.** Every draft spun for two
  minutes and then failed. Two causes, both in the shared OpenAI call: the model
  rejects the temperature the drafters were sending, and the attempts that
  didn't send one ran past the 60s timeout before they could answer. Drafting
  now sends no temperature to a model that only accepts the default, asks for
  minimal reasoning effort, and allows longer for the answer — a word list comes
  back in about 9 seconds and a four-page set in under a minute. (Admin only.)
- **A printable's main listing photo now leads with the board itself, not one of
  its extra pages.** The three pages in the hero image fan out with the middle
  one in front, and that middle card is what shows in an Etsy search grid — but
  the main board was being dealt into the back of the fan, so the page selling
  the listing was whatever came next in the set: a keyboard page, or a
  half-empty one. The main board now sits in the middle, in front. Existing
  listings pick it up the next time their images are regenerated. (Admin only.)
- **Building a board set no longer occasionally creates the whole set twice.**
  If a build hit an error in the moment after its boards were written but before
  it recorded them, the automatic retry built a complete second copy — root and
  every page — and the first copy was stranded: still published, invisible to
  the build page, skipped by publish and unpublish, and left behind when the
  build was deleted. A build now claims its boards in the same breath it creates
  them, so a retry can never duplicate them, and a double click on "Build this
  board" no longer starts two builds. Sets already stranded can be found and
  cleaned up with `rake admin_board_builds:orphans`. (Admin only.)
- **A printable's listing copy now counts the board pages a buyer prints, not
  the front matter around them.** Every printable PDF is wrapped in a cover, a
  how-to-use page, a license and a credits page, and the page count quoted in
  the Etsy description and on the "In your download" panel of the gallery images
  counted all of them — so a one-board printable, whose three board pages are
  the whole product, was sold as a "7-page board PDF". It now reads "3-page
  board PDF", and a set counts each board once per colour/low-ink/trim-ready
  file. Existing printables report the corrected count without being
  regenerated; the admin listing and TPT's "Number of pages" field still show
  the real merged page total.

- **A page's back tile now really does land where the tile that opens it sits.**
  On admin-built boards the alignment quietly did nothing whenever the parent's
  folder tile sat at the far right of its own last row — the most common place
  for it — because the page it opens usually has a shorter last row, and the
  mirrored cell was slid along that row to the final tile: exactly the
  bottom-right corner the back tile was already written into. It now backs up a
  row and keeps the column, so the way home sits directly under the column you
  tapped to get there.

- **Only a communicator's owner can generate their Safety ID card or device
  tag.** The endpoints that build those printables checked that you were signed
  in but never checked *whose* communicator you were asking about — so any
  signed-in account could request another family's Safety ID card and be handed
  a working link to it, allergies, medications, emergency contacts and all. They
  now answer the same way the rest of the emergency info does: owner (or a
  SpeakAnyWay admin) only, and everyone else is refused before anything is
  generated. Note for SLPs and other team members: generating these two
  printables was never meant to be yours to do, and now isn't — ask the family
  to download and share them.

### Changed

- **Care & routine notes: better questions, and you can pick more than one
  answer.** Every care choice is now multi-select — support is layered, and
  being forced to pick the single truest option meant a card that was only
  half right. The "how much help do you need" and "how long to respond" ratings
  are gone, replaced by things a helper can act on ("wait and pause", "keep my
  device close", "food cut up"); `echolalia` is no longer offered as a
  communication method; and the per-section "Good to know" box is gone, since
  the detail lines added last release sat right beside it asking the same
  question.

### Fixed

- **Signing up with an email that already has an account no longer dead-ends.**
  The signup endpoint now tells the app *why* it refused (`error_code:
  "email_taken"`) instead of only handing back a validation sentence, so the
  form can offer to sign the person in rather than printing "Email has already
  been taken" at them. Same contract the email-only checkout signup already
  used. A soft-deleted account's email also returned a server error instead of
  this message — it now takes the same path.

### Added

- **Admin board builder: mark a tile for AI art before you build it.** The art
  review screen exists to catch a symbol the library got wrong — a word that
  resolves to a picture of something else entirely — but until now the only fix
  was to build the board and repair it afterwards. Each tile now carries a
  "regenerate with AI" checkbox. Ticking it changes nothing on the review screen
  (that screen still writes nothing at all); the board is still built with the
  library's symbol, and AI art is generated over it right after, becoming that
  image's current picture. Tiles with no library art are shown ticked and
  greyed — they were always going to be generated.

- **You can print a care plan for your communicator.** Everything you've
  filled in — how they communicate, personal care, meals, sensory, moving
  around, getting around, and any sections you wrote yourself — comes out as a
  clean PDF you can hand to whoever is looking after them. Two versions:
  **Care & Emergency Plan** puts allergies, medical conditions, medications
  and your emergency contacts on the front page, then the day-to-day
  routines; **Care Plan** is the same routine information with none of the
  medical detail. Both carry a QR code back to the live page, because paper
  goes out of date and the page doesn't.

  It's built to stay short. A typical profile comes out at about half a page,
  so it can go on a fridge or in a substitute teacher's folder without being a
  stack — the emergency details sit in two columns, the day-to-day sections
  flow in two more, and emergency questions you left blank are summed up in a
  single line ("No allergies, conditions, medications, or notes were
  provided") instead of taking a row each. Longer plans keep flowing onto as
  many pages as they need; nothing is ever cut off to make it fit.

  Downloads live under **Print & share** on the communicator's page, and only
  the owner can generate them — they're never offered on the public MySpeak
  page. If you haven't filled in any care sections yet there's nothing to
  print, and we'll say so rather than handing you a sheet of empty headings.

- **Two new care sections: Sensory and Moving around.** Noise on the bus and
  lights in a classroom cut across every other section and had nowhere to live,
  and a wheelchair or a pair of AFOs is true all day rather than being a fact
  about the trip to school. Sensory covers sound, touch, light, and what helps
  when it's too much; Moving around covers equipment and the kind of support
  someone needs.
- **Tiles can now be shown without their picture.** The board editor's bulk
  "Hide pictures" toggle sends `payload[:hide_pictures]` to
  `PUT /api/board_images/update`, which blanks `display_image_url` on each
  selected tile. The tile keeps its word, colors, and audio and still speaks —
  only the picture stops being drawn, which is what a letter or keyboard board
  wants. Switching the toggle back off restores the tile's default art. A blank
  url is the "no picture" marker the app, the PDF/print renderer, board covers,
  and printables already share (#683), so this works everywhere on day one
  rather than only on screen. This is a different thing from `hidden` ("Hide
  tiles"), which drops the tile from the board entirely. Omitting the param
  leaves the tile's picture untouched, so layout- and color-only saves can't
  disturb it.

- **A failed renewal now has an end date.** `past_due` was designed as a grace
  state — Stripe keeps retrying the charge and access continues — but nothing
  ever ended the grace, so when the terminal cancel event never arrived (dunning
  set to leave the subscription past_due, or a missed webhook) an account kept
  paid limits indefinitely. Accounts past_due longer than `PAST_DUE_GRACE_DAYS`
  (default 30) now drop to Free with a subscription-ended email. Nothing is
  deleted: over-limit boards go read-only with one still editable, and
  over-limit communicators enter fallback. If Stripe says the subscription is
  paying again, the account is restored to active instead — and if Stripe can't
  be reached, nothing changes.

- **Care options can now be retired without destroying answers people already
  gave.** Removing a choice from the care registry used to erase it from every
  profile still holding it, the next time that profile was saved for any reason
  at all. A retired option is now still accepted on save while no longer being
  offered, and `rake care:audit_options` / `rake care:remap_options` move the
  stored answers onto their replacements before the option is finally deleted.

- **Care sections take detail lines, not just pick-from-a-list answers.** The
  preset choices answer "which of these applies"; the thing you actually need to
  pass on to a substitute is usually specific and still changing — "Drinks:
  watered-down apple juice, we're trying others", "Pieces: cut big ones up",
  "Won't eat anything cold". Every built-in section now takes up to eight
  label/value lines alongside its presets, the same rows a section you write
  yourself already had.

- **The care schema is now served to the app** (`GET /api/care_sections`).
  The editor's option chips came from a copy of the list hand-maintained in the
  frontend, and `sanitize_care_settings` drops an option it doesn't recognize
  rather than rejecting it — so renaming one here silently erased that answer
  from every profile on its next save, with no error anywhere. The app now
  renders whatever this endpoint sends. Changing the care options no longer
  needs a matching frontend release.

- **Text tiles: a tile picture rendered from typed text.** New
  `POST /api/board_images/:id/create_text_image` renders the tile's word in a
  chosen font, size, weight, case, alignment and colors, and attaches the PNG
  exactly like generated art — so print, PDF, OBF/OBZ export and the offline
  cache all treat it as an ordinary tile image. **Free**: no OpenAI call and no
  credit charge, drawn in-house with the existing headless-Chrome pipeline. Five
  OFL typefaces ship vendored (Atkinson Hyperlegible, Andika, Lexend, Nunito,
  Fredoka). Runs on its own `text_images` Sidekiq queue and its own rate-limit
  bucket so it never competes with paid AI work, and an identical repeat request
  is served without re-rendering. `POST /api/images/generate` now rejects
  `style=text` (422) rather than silently falling back to an AI style.

- **Care sections on a MySpeak page.** Beyond the intro and About Me blurb, a
  communicator's page can now carry optional, structured sections covering how
  they communicate, personal care, meals and snacks, and getting to and from
  places — mostly pick-from-a-list answers rather than paragraphs, so a
  substitute teacher or bus driver can scan them in seconds. You can also add
  your own sections for anything the built-in four don't cover. Like emergency
  info, none of it shows on page-load: a visitor has to open it deliberately.
  Unlike emergency info, opening it does **not** send you an alert — these are
  everyday support details, and an email every time someone checks a snack rule
  would drown out the alert that matters. Every view is still recorded. (This
  release adds the data and the page's API; the editing screen and the redesigned
  public page follow.)

- **Every board printable now includes a third, trim-ready PDF.** Alongside the
  full-colour and low-ink versions, each board is printed once more with the
  header removed so the board fills as much of the sheet as possible — the
  version to print when you're cutting and laminating. The QR code moves to the
  top corner rather than disappearing with the header, so the free audio
  companion is still one scan away after the page has been trimmed. A single
  board arrives as one file holding all three; a board set arrives as three
  files, each with its own cover and instructions.

- **Regenerate and delete board printables from the admin dashboard.**
  *Regenerate* rebuilds a printable's PDFs from the board as it is now — the
  sub-board tree is re-walked, so pages added since the first run are picked up
  — while keeping the listing copy you already reviewed and any Etsy draft it's
  linked to; the old downloads are replaced only once the new ones are safely
  built. *Delete* removes a printable and its files. An Etsy draft is never
  touched by either action, so deleting says plainly that the draft is still
  sitting in the Etsy seller UI waiting for you to remove it there.

- **Board printables can be listed for sale from the admin dashboard.** A
  finished printable's page now carries the whole last mile: a link to the board
  it was built from (and every sub-board in the tree), editable listing copy
  generated from the board's own name and topic, marketplace gallery images
  rendered from the same templates as the printed pages, a **Create Etsy draft**
  button that talks to the Etsy API directly, and copy-to-clipboard blocks for
  Teachers Pay Teachers — which has no seller API — laid out field by field in
  the order their upload form asks for them. Nothing here can put a listing
  live: Etsy listings are created as drafts and published by hand, after a human
  has looked at the category, the photos, and the return policy.

### Changed

- **A page's "back" button now sits where the button that opened it sat.** When
  a built board set puts a folder tile in a given spot on the main board, the
  page it opens puts its way home in that same spot — at every level, on every
  page. Previously the back button landed wherever the word list happened to
  leave it, usually the bottom-right corner, so finding the way home meant
  re-scanning the grid on each page instead of reaching for the same cell. The
  word that was in that spot swaps into the corner, so no tile is lost and the
  grid stays full. Applies to admin-authored board sets and to sets from the
  Board Builder; imported OBF/OBZ boards keep their own layouts untouched.

- **The listing gallery's tablet slide now shows the SpeakAnyWay app, not a
  printout.** The board sits inside the app's own header — board name, speech
  bar, play/clear/download — instead of being a printed page with its scan-me
  band warped onto the glass, so the slide reads as "this also opens on the
  tablet you already own" rather than as a photo of paper taped to a screen.

- **Board printables now get a real listing gallery.** The marketplace images
  used to be the printed cover and a text slide, shrunk onto a square mat —
  honest about what you're buying, but invisible next to purpose-built art in an
  Etsy search grid. A printable now gets six square marketing slides: a hero
  showing the actual board pages in a room setting, under an instant-download
  banner and a "free audio companion — every word speaks" badge; the board
  itself shown on a tablet held in someone's hands, so "it also opens on a
  screen" is something a buyer can see rather than read; a what's-included grid
  that names every board in a set; the same grid again in low-ink, so the
  low-ink version is shown rather than claimed; a four-step how-it-works with
  the "scan to try this board free" code in the footer; and an about slide. Every one is generated automatically — there's still nothing to
  make by hand. Printables made before this keep their old images until you hit
  **Regenerate** (the admin page flags them, publishing re-renders on its own,
  and `rake printables:refresh_listing_images` does them in bulk).

- **Every listing gets its own colours.** The gallery slides pick one of five
  on-brand colourways from the board itself, independently of which room photo
  the hero draws, so a shop page of printables doesn't read as one product
  photographed five times. The pick is stable: regenerating a printable never
  re-skins a listing that's already live.

- **Listing copy says "free audio companion" instead of "free voice output".**
  Across the gallery slides and the Etsy/TPT description text. It's the single
  biggest differentiator against every other AAC printable on the marketplace,
  and "voice output" is jargon a parent shopping for their kid doesn't parse.
  Listings already published keep the copy saved on them.

- **Admin board builder: folder tiles now open their page without speaking.**
  A tile that opens another page is a door, not a word — tapping "Food" to get
  to the food page was putting a word into the utterance the communicator
  hadn't chosen to say. Every tile the builder links to a page (a child's "back
  to home" tile included) is now built muted, matching how the communicator
  board builder has always treated its folder tiles. The art preview labels
  these tiles "silent" so it's clear before the board is built. Boards already
  built are repaired by `rake admin_board_builder:mute_folder_tiles`.

### Fixed

- **Printed boards now match what's on screen.** A tile you've cleared the
  picture off — the colour swatches on Core Safety, for instance, which show
  the word on a coloured square — was printing a symbol anyway: an apple on
  "red", a crayon on "blue". The sheet borrowed the stock picture for the word
  instead of honouring that the tile has none. This affected the downloadable
  PDF, the board's cover image, and the printables, since all three come off
  the same renderer. Covers already generated are refreshed by
  `rake board_covers:refresh_blanked_tile_covers`.

- **Printed care plans, safety cards, and device tags stop rebuilding
  themselves.** Each one is meant to be built once and reused until something
  it shows actually changes. Saving the finished document quietly counted as a
  change to the communicator, so the saved copy was already considered
  out-of-date the moment it was written — and every later download rebuilt it
  from scratch. Downloads that used to take seconds now return the copy
  already made, and a real edit still rebuilds it.

- **"Regenerate from tiles" works on every board, and tells you what actually
  happened.** Pages inside a built or imported board set were skipped outright —
  they take their cover from the folder tile that opens them, and asking for a
  fresh snapshot quietly did nothing. Asking for one page at a time now renders
  it like any other board. (Building or importing a whole set still doesn't
  render every page: a large set is hundreds of pages, and doing them all would
  hold up everything else in the queue.) The button also only ever queued the
  work and answered "started", so every way it could fail looked identical to a
  slow success — a snapshot that failed to render gave up out of sight, and you
  were told the cover would "appear shortly" when it never would. A failed
  render now reports itself, a board with no tiles yet says so immediately, and
  the app watches the render's own result rather than guessing from the
  picture's address — so a regenerated cover that happens to look the same still
  counts as done.

- **Saving one part of a communicator's settings no longer wipes the rest.**
  The communicator screen saves settings from several different places, and
  each one sent only the handful of values it knew about — so saving from one
  tab quietly erased what another tab had set, including the dashboard column
  layout and which team a communicator belongs to. Saving now updates only
  what you actually changed. Clearing a setting still works exactly as before.
  A related crash is fixed too: updating a communicator that had never had any
  settings saved could fail outright.

- **Deleting a page in a board set no longer offers to delete the set's home
  board.** A page's "go back" tile is stored the same way as a tile that opens a
  sub-page, so deleting a page counted everything its back tile reached as one
  of that page's own sub-boards — on an imported set, the delete dialog listed
  the set's home board as something it could delete along with the page. Back
  tiles are now recognised as going back, so the dialog only ever offers the
  pages a board genuinely owns.
- **MySpeak pages load fast again.** Opening a communicator's public page —
  the page a printed QR code lands on — was taking around eleven seconds. Every
  visit was rebuilding the entire public board library from scratch, in the
  same detail the board editor needs, when all the page draws is a grid of
  covers. The page now sends just what the grid shows and reuses the library
  between visitors, so it comes up quickly on a phone in a waiting room.

- **Public profile pages load again for users who have favorited a board.**
  A page could fail outright rather than render — the error depended only on
  whether the owner had ever starred one of their own boards.

- **Public pages no longer include information about other people.** The board
  data on a MySpeak page carried details that were never shown but were sent to
  every visitor anyway: the names of other communicators using the same public
  board, and the email address of whoever assigned a board to this
  communicator. The same was true of your own public profile page, where the
  board list carried the names of *your* communicators to anyone who opened it.
  Public pages now carry only what the page renders — the board's name, cover,
  and colours. Nothing about how these pages look has changed.

- **Boards no longer end up with a permanently blank cover.** An imported board
  never had a preview picture made for it at all, so it showed an empty frame
  on the import screen and in your board list until you happened to edit it.
  Separately, and on every kind of board, a cover could fail to appear whenever
  a tile's artwork wasn't finished yet — the picture generator waited forever
  for art that hadn't arrived and gave up with nothing. Covers are now drawn
  even when some artwork is still coming, using the word itself in place of any
  picture that isn't ready, and the cover is redrawn once the real artwork
  lands. Printable PDFs are unaffected — they still wait for the real artwork.
  The pages inside an imported set now show a picture too: each one uses the
  folder tile you tap to open it, the same way a built board set already did.

- **A board set made from your own linked boards showed broken thumbnails.**
  Making a set from a board and the pages it links to left every page with an
  empty picture box. Those pages now get the same treatment as an imported or
  built set — each shows the folder tile you tap to open it, falling back to
  one of its own tiles — and the set itself picks up a cover from its first
  board, so it looks right the moment it's created. Existing sets are fixed by
  a one-off backfill.
- **Etsy was cropping the edges off every printable's listing photos.** The
  gallery slides are square, on the assumption that Etsy letterboxes anything
  that isn't — but the listing page frames a photo 4:5 and crops 10% off each
  side, which took the first letter of the board name and better than half the
  QR code on every listing in the shop. All six slides now keep their text, QR
  code and logo inside a safe margin so nothing meaningful can be cropped away.
  Existing listings pick this up when their images are regenerated.

- **Boards built through the internal API still came out Title Cased.** The
  endpoint treated the word you send as authored display text and pinned its
  casing, so a word list typed the natural way — "Yes / No / Say it again" —
  built a board that read exactly that, sitting next to lowercase tiles from
  every other path. The word now gets the same lowercase default as everywhere
  else. Deliberate casing ("iPad", "TV", "HELP"), folder tiles ("Food"), and an
  explicitly supplied display label are all still kept exactly as sent.

- **Board pages were being sliced off at the bottom of the listing images.**
  On the what's-included slide especially, each board page was cut short of its
  last row — a broken-looking image on the one slide whose job is to show what
  you get. The page cards are now sized from the thumbnail's real dimensions, so
  nothing is cropped, and the pages are sized to leave room for the panel
  listing what's in the download rather than crowding it out.

- **The founder photo sat off-centre in its circle on the about slide.** The
  crop had no effect at all — the source photo is square, so there was nothing
  to shift inside a square frame.
- **New boards kept coming out Title Cased, even after the casing backfill had
  been run.** Tiles are meant to default to lowercase ("happy", "all done"), but
  a freshly built board still rendered "Happy" and "All Done" — and re-running
  the fold reported nothing left to fix. The stuck capitals were not in the
  label columns the backfill reads; they were in the per-language copy of the
  tile text stored alongside each symbol, which a tile reads first and used to
  copy verbatim. So the fold cleaned the columns, the next board re-inherited
  the capitals from the untouched copy, and the loop repeated. English entries
  are now case-normalized like any other defaulted text, and the backfill folds
  them too. Genuine translations are untouched — a Spanish board still renders
  exactly what was translated for it.

- **Marketplace gallery images were rendering at a quarter of their intended
  resolution.** The listing images for a board printable were meant to come out
  at 2040px square, comfortably over Etsy's 2000px recommendation, but the
  retina scale was being passed where the renderer never reads it — so every
  image uploaded so far was 816px, soft on a desktop listing page and softer
  when Etsy zooms it. The images are full size now. Existing listings need their
  images regenerated from the admin page to pick this up.

- **Importing an .obf file did nothing at all.** The file analyzed fine, but
  clicking Import dropped you back on the boards list with no new board and no
  error — and nothing in the logs either. The import was failing on a blank
  slug the moment a single slug-less board existed anywhere, and the job wrote
  that failure at a log level production doesn't record, so it failed in total
  silence. Imports now create their board up front, so the request answers with
  something to follow: both .obf and .obz land on a progress screen that shows
  the import running and says so plainly if it fails, instead of leaving you to
  guess whether it worked. Boards left stranded by the old behavior are
  repaired by `rake obf_import:cleanup` — one that got its tiles is marked
  finished, one that never got any is marked failed, and nothing is deleted.

- **Words on newly built boards were still coming out Title Cased.** Tiles are
  supposed to default to lowercase, the AAC core-vocabulary convention, and the
  creation paths were fixed for that — but cloning a board copied the source's
  tile text over the top of the fold, one step after it happened. Since the
  Board Builder builds every set by cloning a seed board, and those seeds were
  authored before the rule existed, every built board inherited their casing:
  "Higher" next to "swing" on the same page. Cloned word tiles are now folded
  like any other defaulted tile. Folder tiles — the ones you tap to open a page
  — keep their capital, and deliberate casing ("iPad", "TV", "HELP", "I") is
  left alone as always.

- **MySpeak pages published setup instructions as the communicator's own
  words.** Every profile was created with placeholder copy already saved into
  its bio and intro, so any page that had never been personalized greeted
  visitors with "Write a short bio about yourself. This will help others
  understand who you are and what you do." — printed as About Me and read
  aloud in the communicator's voice. Nothing writes that copy any more, and a
  migration clears it from existing profiles (81 of 284 profiles in the
  development database were carrying it). Bios and intros people actually
  wrote are untouched, including ones that happen to quote the phrase.

- **Core 60/84 Food pages: the "More" folder opened nothing, and the "more"
  word tile was missing.** The authored Food page is the one page in each set
  that lists the `More` folder before the `more` word, and the two share one
  symbol — so the importer's link step credited the word's (unlinked) button and
  left the folder tile dead, then the duplicate-tile cleanup mistook the dead
  folder for a copy of the word and deleted the word. Both tiles now import
  correctly on every page of both sets, and every built board set is checked for
  dead folder tiles on all of its pages, not just the home board.

- **Admin board builder: pages were being built with nothing to open them.** A
  page only became reachable if the main board's word list carried a hand-typed
  `>page_key` tile, and only "Draft the whole set with AI" ever wrote one — so
  adding a page by hand, drafting a page on its own, or re-drafting the main
  board after a set draft produced pages that built, published, and went live
  with no tile a communicator could tap to reach them. The folder tile is now
  written onto the main board automatically for any page nothing opens, room is
  made for it if the board is already full, and the builder says what it added
  and what it displaced. A mistyped page key on a tile that plainly names the
  page is repaired rather than rejected. As a backstop, a plan with an
  unreachable page no longer passes validation.

### Added

- **You pick the page names when the admin board builder drafts a whole set.**
  "Draft the whole set with AI" now keeps every page key and name already typed
  on the form and only names the pages left blank — previously it replaced the
  pages wholesale, so a chosen title survived only by being retyped afterwards.
  Naming more pages than the page count asks for raises the count instead of
  dropping them. A new "Suggest page names" button fills in the page titles on
  their own — no words — so the shape of the set can be read and edited before
  any word list is drafted under it.

- **The admin board builder can draft one page at a time from its title.** Each
  page block gets a "Draft this page with AI" button that fills only that page's
  word list, worked out from the page's own name with the board's topic as
  context — the main board and every other page stay exactly as typed. Previously
  the only way to get AI words onto a page was "Draft the whole set", which
  replaced everything. Drafted pages come back with a "back" tile already
  pointing home, and there's no four-page limit the way the whole-set draft has.

- **Deleting a board can now take its subboards with it.** A board whose
  buttons open other boards asks before deleting, and offers an optional
  "Also delete its N subboards" that removes the whole linked set in one go.
  Subboards that something else still uses — another board's button, a
  communicator's dashboard, a team share — are kept and named in the warning.
  The option is off by default: confirming without it deletes only the board
  you asked for.

### Changed

- **Recorded tile audio is converted to mp3 before it can be tapped.** A
  recording made in Chrome arrived as webm, which Safari on iPad won't play —
  so a parent's recorded voice was silent on the device the communicator
  actually uses. Uploads are now normalized in the background, and formats we
  can't convert are refused up front rather than stored. Audio uploads are
  also size- and type-checked, like video already was.
- **Picking which audio file a tile plays is resolved server-side.** The API
  takes the id of one of the tile's own audio files instead of a URL supplied
  by the client.

### Removed

- **The old `/users` and `/users/admin` HTML pages are gone.** They pointed at
  route helpers that no longer exist, so every visit — admin included — was a
  500. Everything they showed lives in the `/admin` dashboard. `/users/:id`
  (profile view/edit) stays and now renders again.
- **Admin-built boards land published and print-ready.** A board built from the
  admin Board Builder is now live at its `/pb/<slug>` page the moment it
  finishes, and appears in the board list on the admin printables page without
  a search. They stay out of the public catalogue on purpose — publishing makes
  a board shareable and printable, not featured. Unpublish (still set-wide)
  reverses it, and a published board still has to be unpublished before it can
  be deleted.

- **Board builder word-count validation now allows a small margin.** A word
  list within 2 tiles of the page's tile count is accepted instead of
  requiring an exact match — the message and the live word-count hint on the
  form now say "within 2" rather than "exactly." A gap larger than that still
  blocks preview/build with the same "Add N" / "Remove N" guidance.

### Fixed

- **One account could edit another account's profile.** The legacy HTML pages
  under `/users` — the old admin area, kept alongside the `/admin` dashboard —
  had lost their permission checks: any signed-in person could rename or change
  the voice settings of any other account by visiting its URL, and could delete
  another account's uploaded document. Those pages are now restricted to the
  account's owner and to admins, matching the `/admin` dashboard. The `/admin`
  dashboard itself was already gated and exposed nothing.
- **A built board set keeps its clean, single-screen home board.** Extra
  category pages the builder added — Bathroom, Animals, My Favorites — used to
  land on a row of their own below the core words, so a Core 60 board came out
  reading "61 tiles" with one stranded folder and a home page that scrolled.
  Those pages now go inside the "More" folder, which sits on the bottom row of
  every page in the set, so they stay a couple of taps away and the home board
  looks exactly as designed. Leftover interest words that previously had
  nowhere to go are surfaced there too instead of being dropped.

- **"Reset to Default Voice" was unreachable.** The API never told the app a
  tile was on custom audio, so the button that undoes a recording never
  appeared — and choosing a synthesized voice from the list didn't clear the
  custom flag either, leaving the tile permanently out of the board's voice.
  Recording, choosing a voice, and resetting now all move the tile cleanly
  between custom and synthesized audio, and the board updates live.
- **Audio could resolve to another account's file.** Audio lookups matched on
  filename across the whole library, and filenames are built from the word and
  the voice, so the same word in two accounts collided.
- **Recorded clips showed a garbled voice name** (e.g. "you-custom") in the
  tile's audio list; they now read as a recording.
- **Uploading audio from the image editor failed outright** with a server
  error, and saved the file without its extension.

- **The admin Board Builder's Tiles spinner now skips to the next whole row.**
  Clicking up on a 6-column board went 24 → 25 — a count the form then rejects
  for leaving dead cells — and the correction only landed if the field happened
  to fire a change event. Tiles now steps by the column count (24 → 30 → 36),
  follows a page's own column override, and re-snaps whenever the columns change
  or a build is loaded back in. Ticking "allow a partial row" returns it to
  stepping by one.

- **Tiles stopped coming out Title Cased.** The lowercase tile default was a
  no-op on the exact input it existed to fix: any capital at all counted as
  deliberate styling, so a word that arrived "Fun" or "Giraffe" — however it was
  created, admin or not — bailed out and stayed capitalized forever. Only a
  capital past the first letter is deliberate now ("iPad", "TV", "McDonald's",
  and the pronoun "I" are all still safe), and it's judged per word, so one
  styled word no longer exempts a whole label. Category tiles keep their capital
  on purpose — "Food" is a page you open, not a word you speak.
- **New words no longer pollute the image library with a stuck capital.** The
  fold now happens in the one place authored casing becomes an image's display
  text, so every path that creates a word — the board editor, word lists, AI
  drafts, imports — gets it, instead of the handful that had been patched
  one at a time.
- **Boards built before the fix can be corrected.** `bin/rails
  labels:fold_casing_report` shows exactly what would change and writes nothing;
  `labels:fold_casing APPLY=1` applies it. Scopeable to a single board or user,
  skips category tiles by default, and only ever re-cases text — it can never
  change what a tile says.

- **Words made from the admin dashboard could permanently stick in Title Case.**
  Creating a tile for a brand-new word (no matching image in the library yet)
  baked in whatever casing it was authored with — a word-list line typed with
  a capital, or an AI-drafted label — as that image's display text forever,
  since any existing capital reads as deliberate styling ("iPad", "TV") to the
  tile-casing default. New images now fold a plain leading capital down before
  it's captured, so a first-time word defaults to lowercase like the rest of
  the board; genuinely stylized casing is untouched. Same underlying path the
  regular board editor uses, so it's fixed there too.

## [1.4.1] — 2026-08-08

### Changed

- **The board builder asks for a tile count instead of rows.** The board never
  stored a row count — it works out rows from how many tiles there are — so
  "6 × 4" was really just "24 tiles" wearing a disguise. The field now says what
  it does. The rail against dead cells moved with it: a tile count that doesn't
  fill whole rows is flagged, with the two nearest counts that would, and
  "allow a partial row" is still there for when you mean it.
- **The board build preview shows the real layout.** The review grid was always
  six tiles across no matter what you authored, so an 8-wide board was reviewed
  at a width it would never be used at. Both the art preview and the built-board
  page now draw the board at its own column count, and each page of a linked set
  at its own.

### Added

- **The board build review page opens the board in a new tab.** Every built
  board — and every page of a linked set — now has an "open" link straight into
  the app, so you can try the real thing before publishing instead of judging it
  from the tile grid. Once a board is published, the `/pb/` public URL becomes a
  link too.
- **The board builder works out the name, topic and audience for you.** Give it
  any one of them — or just paste a word list — and it fills in the rest: what
  the board should be called, what it's about, and who it's for. The last two
  steer both the drafted word list and the art generated for words the library
  doesn't cover. It runs on its own when you draft, or on demand from a button.
  Anything you've typed yourself is left alone.
- **The admin board builder can build a linked set of pages, not just one
  board.** Add pages to a build, give each one a key, and point a tile at it —
  that tile becomes a folder that opens the page, and a tile on a page can point
  back at the main board. Every page shares the main board's grid unless you
  explicitly say otherwise, so cell size doesn't change under a communicator's
  finger as they move between pages. The art review covers every page before
  anything is written, and publishing moves the whole set at once — a published
  board whose folder pages were still private would have led to dead ends.
- Admin Board Builder can draft a whole linked board set — main board plus up to four pages — in one AI call.
- Admin Board Builder suggests a public description and catalogue tags, and both can be corrected after a build.
- Admin Board Builder: duplicate a past build into the form, a duplicate-name warning at preview, and a button to generate missing tile art.

### Changed

- **Board printables got a real cover.** The four pages that bookend every
  printable — cover, how-to-use, license, and About — were plain black text on
  cream. They now carry the brand: a full-bleed gradient header, the SpeakAnyWay
  typeface, numbered step cards in place of the how-to bullet list, and a
  license page whose terms are marked with checks and crosses. The board's
  public URL is printed as text beside every QR code, so a photocopied or
  laminated sheet still leads back to the board.
- **Each printable file now describes only itself.** A set is delivered as two
  files, and both used to carry the same cover and the same "this comes as two
  files" instructions. The colour file now says it's the colour print and the
  low-ink file says it's the low-ink print — neither mentions the other — and
  the low-ink file opens on its own ink-light cover rather than a full-colour
  one. A single board, which really is one file holding both a colour and a
  low-ink copy, still says so.

### Added

- **Admins can build a dense board from a word list, and see the symbols before
  anything is created.** A new admin page takes a board name, a grid size, and a
  typed word list, then shows the actual picture that would land on every tile —
  flagging words the library has no art for, and words where it returned art
  labelled with a different word. Nothing is written until you press Build, so a
  wrong symbol is caught while it's still free to fix. Boards are created
  unpublished; publishing stays a separate, confirmed step. The word list has to
  fill the grid exactly, because a partial last row leaves visible dead cells on
  a classroom screen — there's a checkbox to override it when you mean to.
- **The word list can be drafted by AI.** Give the builder a topic — and
  optionally who the board is for — and it fills the list with a board's worth
  of words, colour-coded by part of speech, leading with the core words that let
  a communicator say something rather than just name things. It's a starting
  point, not a result: the draft lands in the editable list, and still has to be
  reviewed and previewed like anything typed by hand.
- **Cover-wrapped board printables can be generated in the app.** A sellable,
  print-ready PDF for a board previously required running the
  `speakanyway-printables` GitHub Actions pipeline; its PDF-producing core now
  lives in Rails behind admin-only endpoints. A single board produces one
  6-page document (cover, how-to-use, colour board, low-ink board, license,
  credits). Asking for subboards walks the board's linked-board tree and
  returns two fully-wrapped files — a colour bundle and a low-ink bundle —
  with each board page's QR pointing at that board rather than the root. Work
  runs on Sidekiq; a tree over the board cap is refused up front with a 422
  rather than half-built. The board picker collapses behind a toggle and
  scrolls instead of running the length of the page. It is now a table with
  sortable Board / Subboards / Created / Updated columns — sorting happens in
  the database, so re-sorting changes which boards make the capped list rather
  than just reshuffling the ones already on screen — and each row carries a
  link that opens the board's public page in a new tab.

### Fixed

- **Adding a word to a board finds the picture that already exists for it.**
  Image lookup was case-sensitive, so typing "Swing" (or pasting a Title Cased
  word list) sailed past the curated `swing` symbol and silently created a
  brand-new, art-less image beside it — a blank tile on the board and a
  duplicate in the library, over and over. Every lookup now matches
  case-insensitively and ignores stray whitespace, so the existing artwork gets
  reused. The internal API already worked this way; the rest of the app now
  matches it.

- **Tile text no longer inherits whatever casing the creation path used.** An
  image now stores the word twice: a plain lowercase key it is looked up by,
  and the text as it was actually written. Tiles render from the second, so
  "iPad", "TV" and "McDonald's" keep their capitals while ordinary words settle
  to lowercase — and a folder tile still reads "Food", not "food". Existing
  tiles keep their current text; nothing on a board you already built is
  rewritten.

- **Renaming a published board no longer breaks its printed QR codes.** A
  board's share link (`/pb/<slug>`) is derived from its name, and renaming the
  board used to rebuild that link — silently 404ing every QR code already
  printed onto a board printable, with no redirect. A published board's link is
  now permanent: renaming still works and still updates the board's name
  everywhere, it just leaves the shareable link alone. Unpublished boards are
  unaffected, since nothing has been handed out yet.

### Removed

- **The Events, Placeholders and Organizations screens are gone from the HTML
  admin dashboard.** None was still in use — Events managed one-off
  giveaway/contest pages, Placeholders pre-generated MySpeak profiles for print
  handouts, and Organizations was an unfinished multi-tenant admin — so all
  three screens, their routes, and their nav entries have been dropped rather
  than left to rot. The underlying `Event` and `Organization` models, the public
  `/events/:slug` contest pages, and the MySpeak placeholder-claim API are
  untouched, as are the React admin's own APIs for all three.

### Changed

- **Board Printables opens on the public board list instead of an empty search
  box.** Every published public board is now listed up front with its own
  Generate controls, so the common case — printing one of the curated public
  boards — no longer starts by guessing a board name. The search box is still
  there for any other board. The admin's Sidekiq links (nav and dashboard tile)
  now open in a new tab so leaving for the job queue doesn't lose the admin
  page.

- **Staging no longer sends email to real people.** Staging runs against live
  SMTP credentials, so anything exercised there — signups, invitations, alerts
  — used to deliver genuine mail to whatever address was on the record. Mail is
  now dropped on staging by default. To test a template end to end, set
  `STAGING_MAIL_ALLOWLIST` to a comma-separated list of exact addresses
  (`brittany@speakanyway.com`) or domain suffixes (`@speakanyway.com`);
  everything else is stripped from to/cc/bcc. Production and development are
  unaffected.

### Removed

- Removed the orphaned `User#handle_myspeak_setup`. It built a `ChildAccount`
  plus `Profile` for a MySpeak signup flow that no longer exists, and had zero
  callers anywhere in the app.

### Added

- **The internal API can now correct a tile, not just create one.**
  `PATCH /api/internal/boards/:id/board_images/:cell_id` (and an atomic
  `bulk_update`) swap a tile's symbol, colours or label in place, and `DELETE`
  removes one and resyncs the board's layout. A symbol swap keeps the same
  `BoardImage`, so the grid doesn't move — previously a wrong image or colour
  on an API-built board could only be fixed by hand in the editor, which
  doesn't scale to a set of boards headed for print.

### Fixed

- **Sign-in no longer fails for accounts on a team with a deleted member.**
  Deleted user accounts are kept as soft-deleted records, but the team
  membership rows pointing at them stayed behind. Building the login payload
  tried to read a name and email off those missing users and returned a server
  error, locking every member of the affected team out of the app. Deleted
  members are now simply left out of the team and communicator lists.

- **Image search no longer reports art as missing when it exists.** Searching a
  label like `want` or `where` returned only phrase matches (`i want pasta`,
  `where are the lions?`) and could omit the image labelled exactly `want` —
  the very one a board build attaches. Pre-flight "will this board have art?"
  checks were therefore reporting core vocabulary as uncovered, nearly
  triggering unnecessary AI generation and rewordings. Exact labels now rank
  first, ordered the same way board building picks them, and `resolve=true`
  reports exactly what a build would attach for a label.
- **`GET /api/internal/images/:id` reports licensing.** It previously carried no
  licence data at all, so every image read back as "not commercial safe, no
  licence" whether or not that was true — meaning art attached to boards headed
  for Etsy/print could not be licence-checked after the fact. It now returns
  `has_art`, `source_type`, `original_url`, `license`, `commercial_safe`,
  `attribution_required` and `share_alike`.
- **Bulk tile creation no longer duplicates a board when a request is retried.**
  Large bulk writes could return `500` *after* the tiles had been written; the
  natural client response — retry — produced a board holding every tile twice.
  Label resolution is now batched (two queries for a whole request instead of
  two or three per tile) and the response payload is compact by default, which
  removes most of the work that ran after the write committed. Callers can pass
  an `idempotency_key` to make a retry replay the original tiles instead of
  creating new ones, or `replace: true` so a retry converges on the intended
  board. Pass `view=full` for the previous, heavier response shape.
- **The "Publish this board" toggle works for everyone, not just admins.** The
  server was discarding `published` from anyone who wasn't an admin, so a
  regular user could flip the toggle, get a "Board saved" confirmation, and
  still have an unpublished board — with a public link and QR code that showed
  visitors a 404. Board owners can now publish and unpublish their own boards.
  Curation is unchanged: marking a board as a starter board is still admin-only,
  and publishing your own board does not add it to the public board gallery.
- New folder pages added to a Board Builder set after it was built now belong to
  the set. Previously a page created by turning a tile into a folder escaped the
  set entirely: publishing the set skipped it (so public visitors tapping that
  folder still hit a dead end), deleting the set left it behind, and it counted
  against the plan's board limit even though the rest of the set didn't. Pages
  nested more than three levels deep are also covered now.
- Publishing a Board Builder board set now publishes every page in the set, so
  public visitors no longer hit a dead end when tapping a folder button.
  Unpublishing removes the whole set from public view. Both ask for confirmation
  first.
- Unpublishing a board works again — `published: false` was being silently
  dropped by the update endpoint.
- **"Regenerate from tiles" updates the board cover every time, not just the
  first.** Regenerating produced a correct new snapshot on the server, but every
  version was written to the same CDN path — and the CDN ignores the `?v=`
  cache-buster the app appended, so once an edge had cached a board's cover it
  kept serving that copy. The app reported "Cover updated from your board" while
  the picture stayed put, and appeared to work intermittently because edge
  servers cache independently. Each regeneration now publishes to its own path,
  which the CDN has never seen, so the new cover is visible immediately. The
  superseded image is deleted, so nothing accumulates.
- **Tile text casing is consistent across a board.** A tile inherited whatever
  casing its creation path happened to use — paths handing over a Title Cased
  word list produced `Higher`, paths falling through to the image's lowercase
  matching label produced `swing` — so the same board rendered both. Cosmetic
  on screen, a visible defect in print, where these boards become physical
  signs. Tile text defaulted from the image is now normalized at creation:
  Title Case for English words, sentence case for whole-utterance phrase tiles
  and for non-English boards. A display label you type yourself is never
  touched, and anything already carrying capitals (`iPad`, `TV`, `McDonald's`)
  is left exactly as-is. Existing tiles keep their current casing.
- **Correcting a tile's word category now actually recolors the tile.** The
  callback meant to repaint an image when its part of speech changed never
  fired, and an ordinary save silently re-ran the auto-categorizer over a
  hand-picked category — so corrections either didn't stick or left the tile
  painted its old color (the live case: a "social" tile still showing
  important-function red). Hand-set categories now survive a normal save, and
  the color follows the category.
- **Tiles that never had their own category now inherit the word's category.**
  A tile carrying the stored `"default"` placeholder was painted grey instead
  of taking the color of its underlying word.
- **"stop" is now coded as an important function (red), not a verb (green).**
  In the Modified Fitzgerald key tiles are colored by communicative function:
  a child hitting "stop" is protesting, so it belongs beside no / don't /
  can't and needs to stand out from the action words around it. ("stop!"
  already worked; plain "stop" fell through.) "help" is unchanged — it reads
  correctly as a request verb.
- Added `bin/rails tile_colors:repair` (dry run by default, `WRITE=true` to
  apply) to repaint existing tiles whose stored color drifted from their
  category. Per-board category overrides and deliberately authored colors —
  including explicit colors from OBF/OBZ imports — are left alone.

- **Boards built through the internal API land on real symbol art.**
  `POST /api/internal/boards/:id/board_images` and `.../board_images/bulk`
  resolved a tile label with a naive `find_by(label:)`. Many labels have
  several `Image` rows, so that returned one at random — routinely a blank,
  art-less duplicate — and boards came out almost entirely empty while
  reporting `status: "complete"`. One 60-tile build landed 3 tiles on art.
  Both endpoints now resolve labels through `Boards::ImageResolver`: matching
  is case-insensitive and prefers the image that actually has artwork. When
  the resolved image is cased differently than the label sent, the cell keeps
  the caller's casing so tiles aren't renamed.
- **Tiles for words with no library art no longer stay blank forever.** A
  label with no artwork anywhere now enqueues AI generation, so the tile fills
  in shortly after the request instead of never. Pass `generate_missing: false`
  to opt out. An explicit `image_id` still pins that exact record and never
  triggers generation.

## [1.4.0] — 2026-08-05

### Added

- **Any board that links to other boards can now get a Board Set map created
  for it on demand, not just Board Builder boards.** Previously the
  bird's-eye "set map" only worked for boards the Board Builder wizard had
  already grouped; a board you'd hand-linked together with folder buttons
  had no way to get one. Creating a set now auto-discovers every linked
  board and keeps picking up newly-added links on repeat use.
### Fixed — deleting an account

- **Deleting an account failed outright in production.** Every deletion path —
  the in-app "delete my account" endpoint, admin deletion, and demo cleanup —
  raised partway through and left the account untouched. The anonymization step
  cleared a database column that exists in the schema definition but had never
  actually been added to the production database, so the code worked in every
  environment except the live one. The column is now cleared only where it
  exists.

### Fixed — test accounts counted as real users

- **Internal test accounts can now be marked as such explicitly.** Demo
  accounts were recognised only by email pattern (`bhannajohns+…`,
  `@speakanyway.com`), so test accounts created under ordinary-looking
  addresses were treated as real customers — consuming marketing emails,
  bouncing when the address wasn't deliverable, and inflating growth metrics.
  Accounts can now be flagged directly, and the flag is respected everywhere
  demo accounts are already excluded.

### Fixed — onboarding emails that were never being sent

- **The "make your first board" nudge now actually reaches people.** The daily
  job that emails users who signed up 48–72h ago without making a board was
  selecting nobody — it filtered on `role != 'admin'`, which in Postgres is
  false for the NULL role that every password signup has. It reported "0 users
  nudged" every day for months without erroring. The same bug silently disabled
  the win-back journey and most of the monthly legacy-signup nudge; all three
  now use the NULL-safe `User.non_admin` scope.
- **The welcome journey no longer loses the race with signup.** Triggering a
  Mailchimp journey for a contact who isn't in the audience yet returns a 400,
  not a 404, and only 404s were retried — so when the journey trigger ran ahead
  of the audience upsert (routinely, since signup enqueues both at once), the
  welcome email was dropped. Both responses now upsert the contact and retry.
- **A nudge can no longer be marked "sent" when nothing was sent.** The nudge
  jobs check that a journey is configured and enabled before flagging users,
  so a missing journey ID no longer permanently disqualifies everyone it
  touched. New `mailchimp:nudge_flags:report` / `:clear[<flag>]` rake tasks
  (dry-run by default) repair anyone already stuck that way.
- **The first-board nudge no longer misses people when a run is skipped.**
  Eligibility was a single 24-hour band, so a user was reachable on exactly one
  day — two missed runs and that day's signups were skipped forever, with
  nothing to catch them. It's now a 48h–14d catch-up window (capped at 100
  sends per run); the per-user flag still guarantees nobody is nudged twice.
- **The monthly re-engagement email is now capped at 100 sends per run**
  (`LEGACY_SIGNUP_NUDGE_MAX_PER_RUN`). It's the only nudge with no upper bound
  on how far back it reaches, so with the selection bug fixed a single run
  could otherwise email every dormant account at once. The backlog drains
  across consecutive monthly runs instead.
- **No one receives two marketing emails back to back.** Journey emails are
  triggered from independent places that can coincide — a signup welcome and a
  subscription-started email minutes apart, or two nightly nudges half an hour
  apart. A minimum 4-hour gap per person is now enforced centrally; a message
  that would arrive too soon is delayed rather than dropped.
- **The win-back email is capped at 100 sends per run** (`WIN_BACK_MAX_PER_RUN`),
  matching the other nudges.
- **Demo and internal accounts no longer receive marketing journey emails,**
  so test traffic can't consume real campaign sends or distort a journey's
  open and click rates. They stay in the Mailchimp audience as before.

### Fixed — exporting a large board as `.obz`

- **Exporting a board with many linked boards no longer fails with "Package
  exceeds the 200MB limit."** The `.obz` package bundled full-resolution
  original images, so an ordinary board's predictive-link tree ran to
  hundreds of megabytes and hit the size cap before finishing — one real
  board's 23-board tree carried 665MB of originals. Packages now bundle the
  same display-size tile images the app itself renders (288px webp), which
  brings that board to roughly 25MB. Exported images are described as `webp`
  in the package manifest and re-import cleanly.
### Fixed — upgrading from Free

- **An account whose Stripe customer had been deleted could no longer upgrade
  to any plan.** Checkout trusted the stored customer id, so Stripe rejected
  every session with "No such customer" and the pricing page showed only
  "There was an error choosing your plan. Please try again." — with no way for
  the user to recover. The customer is now verified before use and recreated if
  it is gone. A Stripe outage or network blip leaves the stored id untouched.

### Fixed — importing a `.obf` file
- **Uploading a `.obf` file now imports.** `POST /api/boards/import_obf`
  only handled `.obz` uploads; a `.obf` fell through to
  422 "Unsupported file format". Since the app's own export produces a bare
  `.obf`, nothing exported from SpeakAnyWay could be imported back into it.
  A malformed `.obf` now returns 422 up front rather than enqueuing a job
  that fails out of sight.
- **File analysis no longer reports a garbage file as valid.** `ObzAnalyzer`
  read every upload as a zip, so a `.obf` (or any non-zip) raised internally,
  got swallowed, and returned an all-zero report with HTTP 200 — which the
  import screen rendered as "Looks good — we found everything we need."
  The analyzer now detects the container from the bytes, reports
  `package.format`, produces a real single-board report for a `.obf`, and
  flags files it genuinely could not read with an `error` field.
- Fixed a latent 500 in the JSON-body import path: passing `board_group_id`
  alongside `data` called `merge` on an ActiveRecord model.

### Fixed — `.obf` export of ordinary boards
- **Exporting a single board as `.obf` no longer fails on normal boards.**
  The synchronous path base64-encoded each tile's full-resolution original,
  so a routine 60-tile board ran to tens of MB and tripped the 20MB cap with
  a generic "Export failed". It now bundles the same 288px webp tile variant
  the app displays (falling back to the original when that variant hasn't
  been generated yet, and never generating one mid-request). `.obz` packages
  are unchanged and still carry full-resolution originals.
- Inline export now dedupes by doc, so two tiles sharing one image encode
  and count those bytes once rather than once per tile.
- The `download_obf` 422 now carries an `error_code` (`too_many_tiles` vs
  `export_too_large`) so clients and logs can tell the two caps apart.

### Fixed — `.obz` downloads were blocked in production
- Added `GET /api/board_exports/:id/download_url`, which returns the export's
  storage URL as JSON instead of redirecting to it. The existing `#download`
  redirect can't serve a browser: the web app's requests carry an
  `Authorization` header, so they're preflighted, and a preflighted request
  that redirects cross-origin re-preflights against the new origin — S3,
  which has no CORS rule for our origins and answers 403. Every `.obz`
  download failed in production (single boards and Board Sets alike) while
  the modal reported it as a failed *export*. Only reproducible against S3;
  dev/test use the Disk service, whose URL is same-origin. `#download` is
  unchanged and still serves non-browser callers.

### Added — OBF/OBZ export hardening
- Tile audio is now bundled into `.obz` packages (previously silent on
  export — only images were included). No change to `.obf` structure for
  imports; `ObzImporter`/`Board.from_obf` still don't consume the bundled
  sounds, so a round-tripped package loses its audio (a separate, tracked
  gap).
- The export summary and a new `README.txt` section now list which bundled
  images require attribution under their (CC BY family) license.
- `GET /api/boards/:id/download_obf` (the synchronous path) is now capped at
  200 tiles / 20MB of inlined image bytes; going over either returns a 422
  pointing at the async `.obz` export (`export_package`) instead. The async
  path's own 200MB package-size cap (`ObzPackager::MAX_BYTES`) is now
  checked incrementally as the zip is built, not after the fact.
- `POST /api/boards/:id/export_package`, `POST
  /api/board_groups/:id/export_package`, and `GET
  /api/boards/:id/download_obf` are now rate-limited together under one
  per-user bucket (`RACK_ATTACK_EXPORT_LIMIT`, default 10/hour) and the two
  `export_package` endpoints refuse a second in-flight export per user (409
  `export_in_progress`).

### Fixed — export authorization and performance
- `board_groups#export_package` now returns a generic 404 for an
  unauthorized or nonexistent Board Set instead of a 403 that confirmed the
  id existed, matching the other three export-adjacent endpoints.
- Fixed two N+1 query sources in `Boards::ObfExporter` (per-tile board
  lookups for predictive links, and per-tile `display_doc` lookups) —
  benefits the async `.obz` export path, which is where export volume
  actually lives.
- `GET /api/board_exports/:id/download` now redirects to the file's storage
  URL instead of buffering the whole `.obz` through the app server.

### Fixed — cross-task interactions from the export hardening pass
- `GET /api/boards/:id/download_obf` could bypass the `export/user`
  Rack::Attack throttle entirely (it never created a `BoardExport`, so it
  never tripped the in-flight guard either) — it now shares the same
  throttle bucket as the two `export_package` endpoints.
- The in-flight export guard (`current_user.board_exports...exists?`) used
  to match any `queued`/`processing` `BoardExport` forever, so a job that
  died without reaching its rescue block (OOM, hard kill) permanently
  409-locked that user out of exporting. It now goes through
  `BoardExport.in_flight`, which adds a 30-minute staleness bound
  (`IN_FLIGHT_STALENESS`) — a stale `queued`/`processing` record stops
  gating new exports after 30 minutes, though it doesn't cancel or affect
  an already-running job.
- `BoardExport#file` now attaches to a new private `amazon_private` Active
  Storage service in production (`config/storage.yml`) instead of the
  default `amazon` service, which is `public: true`. Exported `.obz`/`.obf`
  files can bundle a family's own audio recordings, so `file.url` now
  resolves to a signed, expiring URL rather than a permanent unauthenticated
  one.

### Fixed — selecting the Free plan can no longer downgrade a paying subscriber
- `POST /api/stripe/checkout_sessions` with `plan_key: "free"` applied
  `plan_type: "free", plan_status: "active"` to anyone who asked, with no
  guard. That endpoint is also how the frontend's onboarding **"Maybe later"**
  skip is wired, so it fired for people who never intended a plan change —
  observed on staging after a Google sign-in routed an existing customer into
  the onboarding plan picker.
- Worse than a wrong label: it rewrote `plan_type` locally while the Stripe
  subscription kept billing, desyncing the two.
- Entitled accounts (`paid_plan?`, which also covers admins) are now a logged
  no-op. Real downgrades already have a home in `subscriptions#billing_portal`
  / `#change_plan` / `#cancel_subscription`, which cancel in Stripe properly,
  so nobody is stranded. A cancelled subscriber still resolves to free, so
  stranded-plan healing is unaffected.
- Companion to #549, which closed the same hole for *unrecognized* plan keys
  but deliberately left this explicit `"free"` branch alone.

### Added — `POST /api/v1/auths/google` returns `is_new_user`
- The endpoint both signs up and signs in, so the client could not tell a
  brand-new account from a returning customer. That mattered: the frontend
  sends new accounts to `/onboarding` (the plan picker) and returning
  customers to their dashboard, and getting it wrong was the route into the
  downgrade above. The flag is already computed internally; it is now returned
  alongside `token` and `user`.

### Fixed — `POST /api/docs` returns the created doc instead of a 500
- The JSON branch rendered `render :show, location: @doc`. `location: @doc`
  resolves to `doc_url`, but the route is declared inside `namespace :api`, so
  the helper is `api_doc_url` — and there is no `app/views/api/docs/show`
  template for `render :show` to find either. Both faults fired *after* the
  Doc was saved, so the record was created and the caller still got a 500.
- The endpoint now responds `201` with the doc's `api_view` (the same shape
  `PATCH /api/docs/:id` returns) and a `Location` header built from
  `api_doc_url`. The same `doc_url` typo in `#update`'s HTML redirect is fixed
  too. No frontend change: the app only calls `docs/:id/mark_as_current`.

### Added — Export a board as `.obf`, or a Board Set / linked-board tree as `.obz`
- `GET /api/boards/:id/download_obf` downloads a single board as an OBF
  document with images inlined. `POST /api/boards/:id/export_package` (a
  board plus everything it reaches via predictive links) and
  `POST /api/board_groups/:id/export_package` (an explicit Board Set) queue
  an async job and return a `BoardExport` record; poll
  `GET /api/board_exports/:id` and fetch the finished `.obz` from
  `GET /api/board_exports/:id/download`.
- Packages bundle image files SpeakAnyWay may lawfully redistribute on the
  user's behalf and fall back to a `url:` reference otherwise, with a
  `README.txt` inside the package listing anything left out (unbundlable
  images, boards excluded by the read check or the package size cap, and any
  image that could not be read at packaging time).

### Fixed — `download_obf` / OBF export correctness
- `download_obf` now checks read permission before exporting a board (was
  exportable by anyone with the id), and names the downloaded file after the
  board instead of a generic name.
- OBF grid `order` cell ids are emitted as strings so they match the `id`
  emitted for each button, per spec, instead of integers that a
  spec-strict importer won't coerce.

### Fixed — The SpeakAnyWay logo no longer shows up as an email attachment
- Every transactional email attached the logo as an inline (`cid`) image.
  Referencing an inline part from the HTML is legal MIME, but mail clients
  still list *any* attachment part in the attachment strip, so messages —
  "Your subscription was canceled" among them — arrived looking like they
  carried a downloadable `logo.png`.
- The logo is now loaded over HTTPS from `public/email-logo.png` (a 240px
  version of the bubble mark) instead of being attached, so no email carries
  an attachment at all. Set `EMAIL_LOGO_URL` to serve it from a CDN or a
  different domain; by default it resolves against the same host Action Mailer
  already builds links against.

### Added — Google sign-in, backend (Phase 1 of social sign-in)
- New `POST /api/v1/auths/google` endpoint verifies a Google ID token and
  signs in (auto-linking by email to an existing account, or creating a new
  passwordless one) — backend-only, ships independently of the frontend
  Google sign-in button, which is a separate PR against `itty-bitty-frontend`.
  Requires `GOOGLE_OAUTH_CLIENT_ID` set in the target environment.

### Fixed — An unrecognized checkout plan_key no longer downgrades the user to Free
- `POST /api/stripe/checkout_sessions` treated *any* plan_key it didn't
  recognize (a typo, plan-key drift between frontend and backend, a missing
  `STRIPE_PRICE_*` env var) the same as an explicit `plan_key=free` request:
  it silently reset the user's `plan_type` to `"free"` and redirected to
  `/home` with no Stripe session and no error. That's how a paired frontend
  bug (5-Year License buttons posting an unhandled plan_key here) was able
  to bounce users to the dashboard.
- Unrecognized/misconfigured plan keys now get a 400 `Unknown or
  unconfigured plan_key` response and never touch the user's plan record.
  Only an explicit `plan_key=free` still short-circuits to the free plan.

### Fixed — Promo codes are redeemable on annual plans at Stripe Checkout
- Picking a yearly plan from /pricing and typing a promotion code into Stripe's
  own code box failed with "does not meet the minimum amount requirement". The
  14-day no-card trial set the amount due today to $0, and a minimum-restricted
  coupon (the FOUNDING code's $50 floor, which is what limits it to annual
  plans) is validated against that amount. Only the campaign link
  (`/pricing?promo=FOUNDING`) worked, because that path already skipped the
  trial.
- Yearly checkouts now skip the trial whether or not a promo code was passed in,
  so the annual price is due at checkout and the code validates. Monthly
  checkouts are unchanged and keep the full no-card reverse trial.

### Added — Referral attribution on signup links
- Signup now captures a `ref` query param (e.g. `/sign-up/partner?ref=emilydiaz`)
  into `settings["signup_ref"]`, sanitized (trimmed, lowercased, capped at 64
  characters) and only written when non-blank. Applies to both the standard and
  email-only signup paths.
- The ref rides the `user_signed_up` PostHog event and is shown on the admin
  user page, so it's clear which creator referred a partner without opening the
  console.

### Fixed — Welcome emails no longer promise a Supporter limit
- The Basic welcome email said "Invite up to 2 Supporter accounts" and the
  MySpeak claim-link email said "2 included". No such limit exists: the invite
  path (`POST /api/teams/:id/invite`) performs no count check on any plan, and
  the Pro welcome email and the pricing page both already say Supporters are
  unlimited. The copy now matches the product — Supporters are uncapped on
  every plan, in English and Spanish.
- Removed the unused `User#supporter_limit`, which was read only by that email
  copy and never by an enforcement path.
### Added — Payment-method prompt for no-card reverse trials
- `api_view` now returns a computed `trial` block (`active`, `status`,
  `ends_at`, `provider`, `needs_payment_method`, `plan_label`) so the app can
  ask card-less trialists for a payment method instead of a plan they already
  chose.
- `settings["has_payment_method"]` tracks whether Stripe has a chargeable card,
  updated on subscription upsert and on `payment_method.attached`.
- `POST /api/subscriptions/billing_portal` accepts `flow=payment_method_update`
  to open Stripe's focused "add a card" flow.

### Fixed — stale `has_payment_method` flag during a quiet trial
- Stripe fires no subscription event between trial start and the trial-ending
  reminder, so `has_payment_method` could sit wrong (or entirely unset) for a
  trial's full 14 days — missing the "add a payment method" nudge for anyone
  whose card was removed mid-trial, or wrongly nudging a card-required trialist
  who already had one on file. `customer.subscription.trial_will_end` now
  recomputes the flag authoritatively right before the frontend CTA turns on.
- `payment_method.attached` now only writes the flag for a `trialing` user —
  a payment method attached for an unrelated purchase (e.g. a credit top-up)
  no longer masks a trialist's missing card.
- `trial_provider` now honors the same partner_pro trial-UI suppression as
  `show_trial_ui?` / `trial_plan_label`.
- Downgrading to Free now clears `has_payment_method` alongside `trial_ends_at`.

### Added — Email verification for new signups
- Both signup paths (standard signup and email-only/passwordless signup) now
  send a confirmation email. The free welcome tokens and the initial AI credit
  allowance are granted when the address is confirmed rather than at account
  creation. Existing accounts are backfilled as verified and are unaffected.
- Unverified accounts can still sign in and use the app — verification never
  gates authentication — but hold zero welcome tokens and zero AI credits
  until confirmed.
- `POST /api/resend_email_verification` resends the confirmation link,
  throttled per-account (5-minute interval).
- Signup rate limiting (20/hour per IP on `POST /api/v1/users` and
  `/api/v1/users/email_signup`) and rejection of disposable email domains at
  signup.

### Changed — AI image generation now requires a confirmed email address
- Includes the previously-free first-time-fill path
  (`POST /api/images/generate` on an image with no picture yet), which never
  went through the credit ledger and so had no other gate. Unverified callers
  get a generic **403 `email_verification_required`**; admins bypass.

### Fixed — email-change confirmation tokens now expire
- They previously never expired (`confirmation_sent_at` was stored but never
  checked). Same 7-day window as signup verification.
- Confirming an email change now grants verification (and the pending welcome
  tokens and AI credits) to an account that had not yet been verified —
  confirming a pending change is proof of inbox access on the new address,
  the same as clicking the dedicated verification link.

### Changed — the category row is now the same on every page of a built board set
- **Same reach, every page.** The row of category folders along the bottom of a
  built set's home board is now reproduced on every page of that set, in the
  same cells. A communicator learns *where* Food is once, and it's in that spot
  no matter which page they're on.
- **This now covers the pages a build adds.** Previously only the pages that
  shipped with the Core 60 / Core 84 templates had the row, and adding a page
  (an interest category, My Favorites, Phrases) knocked even those out of
  alignment. Every page in a set gets it now, including the gestalt phrase
  pages.
- **The page you're on speaks its own name and takes you home.** That tile is
  the you-are-here anchor, which is why there's no separate Home tile.
- **Pinned to the bottom on tablets and phones**, not just large screens.
- **Existing sets** are brought up to date with
  `rake board_builder:sync_nav_rows` (preview first; `DRY_RUN=false` to apply).
  Nothing a user added is deleted — a tile in the way is moved, not dropped.

### Changed — AI tile images are consistent, transparent, and disambiguated
- **One house style.** Every generated tile now goes through a single prompt
  builder. Six different prompts used to compete ("no stylization" vs
  "clipart-style" vs "simple cartoon illustration" vs "avoid cartoonish
  styles"), so tiles on the same board didn't look like a set.
- **Your prompt is now styled, not passed through.** Typing a longer
  description used to bypass the house style entirely — no AAC framing, no
  "no text" rule — which is why detailed prompts often came back as
  photo-like scenes with letters in them. Your words now describe the subject
  inside the house style instead of replacing it.
- **Backgrounds are actually transparent.** Transparency is requested through
  the image API rather than only asked for in the prompt text, so tiles stop
  arriving with a white box behind them on colored backgrounds.
- **Homographs render correctly.** The part of speech already stored for tile
  coloring now also guides the picture, so "can", "orange", "watch", "left"
  and "back" show the right meaning.
- **Symbol or illustrated style.** Tiles can be generated as flat AAC symbols
  (the new default) or as softer illustrations, settable per user or per board.
- **Variations match.** "Make a variation" ran on a much older image model and
  produced art in a visibly different style; it now matches the tile beside it.
- **Blocked words retry.** A word refused by the content filter (body parts,
  medical or bathroom vocabulary) is retried once with the standard prompt
  instead of failing silently.

### Fixed — Image generation reliability
- Generating an image without a prompt no longer fails outright.
- Filling a board no longer discards a custom prompt written for a tile.
- Regenerating an image no longer repoints tiles on other users' boards.
### Added — Writing suggestions for About Me
- `POST /api/suggestions` returns three short starter sentences for a
  communicator's public About Me, built from their name, age range, AAC level,
  gestalt language stage, and interests. Free — no credits are spent.
- Emergency and medical details are never sent to OpenAI. The field registry
  allow-lists what may become prompt context, and a spec fails the build if any
  `Profile::SAFETY_SENSITIVE_KEYS` entry is ever added to one.
- Users can turn the feature off account-wide via
  `settings["ai_writing_suggestions"]`; absent means on.

### Fixed — Admin signup alerts no longer fire on upgrades
- The "new user signed up" admin email was sent from inside three welcome-email
  methods. Because `send_plan_welcome_email_once!` routes through
  `send_welcome_email`, every Stripe trial→active transition, RevenueCat
  purchase, plan upgrade, and admin-dashboard "Send welcome email" click sent
  an alert claiming a brand-new signup. It now fires from a single idempotent
  `User#notify_admin_of_signup!` at the three real account-creation points.
- The alert also carries real context now: the signup method and platform
  (captured at signup instead of being discarded), a coarse location from the
  signup IP, and deep links to the admin dashboard, the Stripe customer, and
  the Stripe subscription. The legacy `tokens` field was dropped from the body.

### Added — Admin plan-change email
- Upgrades send their own `AdminMailer#plan_change_email`, naming both plans and
  the source (Stripe, RevenueCat, or the billing API). Fired from
  `send_plan_welcome_email_once!`, so it inherits that method's per-plan
  idempotency: renewals and downgrades do not trigger it.

### Fixed — Welcome-email Mailchimp sync can no longer break a signup
- `User#send_general_welcome_email` had a bare `begin`/`end` with no `rescue`,
  unlike its `send_welcome_email` and `send_welcome_receipt_email` siblings, so
  a Mailchimp outage propagated out of it. It now rescues and logs, matching
  the "external-service failures fail soft" invariant.

### Fixed — Feedback email header
- The admin feedback email rendered "SpeakAnyWay has a new user! 🎉" in its
  header, copy-pasted from the signup email.

### Added — Closing the Gap booth lead attribution
- Leads captured with `source: "ctg"` now carry the `ctg-2026` Mailchimp tag,
  so booth signups land in the campaign's existing segment and welcome
  automation instead of the generic lead tag.
### Fixed — Clinician application credential values are normalized
- `ClinicianApplication#credential_type` is normalized to the canonical
  `CREDENTIAL_TYPES` slugs (`slp`, `ot`, `at_specialist`, `other`) before
  validation, and the inclusion rule is now actually enforced. Display labels
  such as `"SLP"` or `"AT specialist"` were reaching the admin review queue
  un-normalized, because the constant existed but nothing validated against
  it. Normalizing *before* validating means an older client still sending a
  label is corrected rather than newly rejected; anything unrecognized becomes
  `other`, which an admin reviews by hand anyway. A migration backfills
  existing rows.

### Added — Internal API image and board search
- `GET`/`POST /api/internal/images/search` — find library images by label
  (single or bulk, up to 100 labels per request) and get print-resolution
  originals, with `commercial_safe` / `attribution_required` / `share_alike`
  flags so sellable printables can exclude non-commercial artwork.
- `GET /api/internal/boards/search` and `GET /api/internal/boards/tags` —
  filter admin boards by tag, name or description, published or not.
- `rake images:license_audit` — read-only report of the image library's
  license breakdown.

## [1.3.0] — 2026-07-21

### Added — Video tiles accept iPhone recordings, and the 30s limit is now enforced
- Tile video uploads now accept **.mov / HEVC** files, so a clip recorded on an
  iPhone can be attached directly instead of being rejected. It's converted to
  a web-safe mp4 in the background, which is what makes it play in Chrome and
  Firefox too.
- The upload limit for these source files is **100 MB** (raw phone recordings
  are large); the converted clip that gets stored and played is much smaller.
- The **30-second limit is now enforced on the server**. Longer clips are
  trimmed to the first 30 seconds rather than silently failing.
- Processing happens after the upload finishes, so the editor isn't blocked —
  the tile updates on its own once the clip is ready.
- Requires `ffmpeg` on the server. Without it, uploads behave exactly as before
  (mp4/webm only, 25 MB) rather than breaking.

### Changed — Board Builder pages are no longer frozen
- Pages inside a built board set now behave like any other board: tapping a word
  returns to the home board. Previously every page of a built set was created
  **frozen**, which kept you on that page after a tap.
- Freezing is unchanged as a per-board option — builder sets simply don't turn it
  on by default.
- Existing built sets are unfrozen by
  `DRY_RUN=false rake board_builder:reclassify_builder_sets` (dry-run by default,
  `USER_ID=N` to scope to one user).

### Fixed — Board Builder nav row now lines up across a whole set
- The category strip along the bottom of a built set (People, Feelings, Food, …)
  now sits in the **exact same grid cell on every page**, so a word is the same
  reach no matter where you are — what AAC motor planning depends on. Previously
  the strip drifted: `Drinks` was missing from every sub-page, which shifted
  every tile after it one cell left, and Core 84's sub-pages were a row shorter
  than the home board and dropped `Time`, `Describe` and `School` entirely.
- The tile for the page you're on is now **present rather than a blank gap** — on
  the People page, `People` sits exactly where you tapped it, speaks its label,
  and takes you back home. It replaces the old `Home` tile.
- Applies to **newly built sets**. Sets are copied from the template when built,
  so already-built sets keep their existing layout.

### Added — Board Builder no longer requires a communicator
- `POST /api/v1/board_builder` now accepts an **omitted `communicator_id`** and
  builds an **unattached** board set owned by the user, which they can assign to
  a communicator later. Previously a user with no communicator couldn't build a
  set at all — and since the manual Board Set form redirects non-admins to the
  Board Builder, that meant they couldn't create a board set by any route.
- Backward compatible: a `communicator_id` that's present but doesn't resolve
  still returns **404 `communicator_not_found`**. Only an absent id is the new
  path, so existing clients are unaffected.
- Without a communicator there's no `ChildBoard` (so the set isn't on a
  dashboard, but does appear in Board Sets), the board voice falls back to the
  user's own default, interests persist on the set's `BoardGroup`, and there's
  no 409 re-run guard — each build is just another Board Set, still capped by
  the board-set limit. No migration.

### Added — Extra communicator add-on slots (Pro-only)
- Pro users can buy communicator slots on top of the base 5: **$5/mo or $50/yr**
  recurring, or **$125 one-time** bundled with a `pro_5yr` 5-Year license.
- Recurring: `POST /api/subscriptions/communicator_addon { quantity }` sets a
  recurring add-on subscription item; the subscription webhook re-derives the
  entitlement from the live subscription so add/remove/cancel self-heals.
- One-time: `POST /api/stripe/checkout_sessions/license` now accepts
  `extra_communicators` (Pro license only); the license webhook grants them and
  they expire with the license.
- Fixes the long-standing gap where the communicator-limit gate read a
  `communicator_slot_limit` override that nothing ever wrote — purchased slots
  are now actually creatable. New ENV: `STRIPE_PRICE_PRO_EXTRA_COMM_MONTHLY`,
  `STRIPE_PRICE_PRO_EXTRA_COMM_YEARLY`, `STRIPE_PRICE_PRO_EXTRA_COMM_5YR`,
  `MAX_EXTRA_COMMUNICATORS` (default 20).

### Added — 5-Year licenses, SpeakAnyWay for Clinicians, and a plan-expiry enforcer
- **5-Year licenses** (`basic_5yr` $199 / `pro_5yr` $499): a one-time Stripe
  payment (`POST /api/stripe/checkout_sessions/license`, `mode: "payment"`, promo
  codes allowed) that grants Basic/Pro-equivalent entitlements for 5 years via
  `plan_expires_at`. The `checkout.session.completed` webhook (`kind=license`)
  sets the plan, a 5-year expiry, and the first month's credits (idempotent on
  the Stripe event id). Licensees have no Stripe subscription, so
  `RefreshFreeTierCreditsJob` re-grants their monthly credits.
- **PlanExpiryJob** (daily, 6am UTC) — the missing enforcer for `plan_expires_at`.
  Scoped to the 5-Year licenses: sends a renewal-offer email ~60 days out
  (`LICENSE_RENEWAL_NOTICE_LEAD_DAYS`), and at expiry drops the user to Free via
  `Billing::PlanTransitions.apply_free_plan` (data retained, over-limit boards
  read-only, over-limit communicators in fallback) plus a "license ended" email.
  `partner_pro`/`clinician` are intentionally excluded.
- **SpeakAnyWay for Clinicians** (`clinician`): a free, manually-approved plan for
  verified SLPs/OTs/AT specialists — **Basic-shaped limits (100 boards / 25
  groups)**, a 2-slot loaner cap (protects school pricing), 400 credits/mo.
  Applicants apply via `POST /api/clinician_applications`; admins review from the
  **`/admin/clinician_applications` dashboard page** (nav "Clinicians" with a
  pending badge, Approve/Deny buttons) or the JSON API
  `GET/POST /api/admin/clinician_applications` — both share
  `ClinicianApplications::Reviewer` (approve flips the plan + grants credits +
  emails; API non-admins get 403). Approval/denial/received emails avoid the
  word "Professional" (collides with the Pro tier). The board read-only lock now
  applies to clinicians: over their 100-board limit, the most-recently-updated
  100 stay editable and the rest go read-only (retained, never deleted) — the
  lock generalized from Free's single-editable-board model to the top-N by
  board limit, with `lock_reason` `plan_board_limit` (vs `free_plan_board_limit`).
- **Partner Pro trial landing** — Partner Pro **stays as-is** (no fold). When a
  partner_pro no-card trial lapses, `handle_subscription_deleted` now lands the
  user on a free, auto-approved `clinician` account (content retained) instead of
  Free. Idempotent (no-op for already-clinician users). `PartnerMailer`
  trial-end copy updated to present the "add a card vs. continue on Clinician"
  choice. Must be live in prod before Oct 14, 2026 (first trials end Oct 14–20).
- **Deploy note:** set `STRIPE_PRICE_BASIC_5YR` / `STRIPE_PRICE_PRO_5YR` (live
  prices `price_1TtVOWGfsUBE8bl32zKryqV4` / `price_1TtVOgGfsUBE8bl3a0wSUIcr`);
  staging needs test-mode twins. Register `PlanExpiryJob` in sidekiq-cron (done in
  `config/initializers/sidekiq.rb`). Migration: `clinician_applications` only.

### Changed — Partner Program pilots now run on a real Stripe no-card trial
- Partner sign-up (`plan_type=partner_pro`) now creates a Stripe subscription on
  the Partner Pro price ($10/mo, `metadata.plan_type=partner_pro`) with a 3-month
  no-card trial. When the pilot ends with no card on file, Stripe cancels it
  cleanly and the user auto-downgrades to Free (content retained) — no more
  partners sitting on Pro forever. Adding a card converts them at $10/mo.
- Extend a pilot with `rake partners:extend USER_ID=N [MONTHS=3]`, which moves
  both `plan_expires_at` and the Stripe trial end so reminders/auto-cancel
  re-arm. Subscription creation is fail-soft (a Stripe outage never blocks
  signup). Partner-facing "pilot wrapping up" nudges are now owned by Stripe's
  `trial_will_end` webhook, which fires a dedicated **`partner_pilot_wrap`**
  Mailchimp journey for partners (names the $10/mo rate; "add a card to continue"
  or "reply to re-up your partner program"). Requires
  `MAILCHIMP_JOURNEY_PARTNER_PILOT_WRAP_ID` / `_STEP` to be set and the journey
  built in Mailchimp.
- **Deploy note:** repoint `STRIPE_PRICE_PARTNER_PRO` from the old $0 price to
  the new $10/mo Partner Pro price `price_1TtA0nGfsUBE8bl3knjA2WOD`
  (metadata `plan_type=partner_pro`) — a $0 subscription never lapses and would
  not downgrade.

### Fixed — communicator roster + delete hardening around the SLP hand-off
- `GET /api/child_accounts` now scopes on `owner_id` (the column slot counts and
  serializers use) instead of the legacy `user_id` mirror, so the listed
  communicators can't diverge from the "X of Y" slot numbers.
- `DELETE /api/child_accounts/:id` authorizes on `owner_id` and refuses a
  lent-out `loaner` (HTTP 422, "End the loan first") — mirroring the archive
  guard so a family's live claim link is never orphaned mid-hand-off.

### Changed — Pro plan now includes 10 sandbox communicators (was 1)
- `PRO_PLAN_LIMITS["demo_communicator_limit"]` default raised 1 → 10 (ENV
  `PRO_DEMO_COMMUNICATOR_LIMIT`, already `10` in production). Pro users can keep
  up to ten no-sign-in sandbox communicators for trialing setups; sandboxes
  still don't count against sign-in slots.
- Existing Pro users are backfilled by the one-off task
  `plans:bump_pro_sandbox_to_ten` (dry-run with `DRY_RUN=true`; skips anyone at
  or above 10, incl. admin-tuned).

### Fixed — /api/boards no longer 500s on an orphaned communicator join row
- `Board#api_view` read `child_account.id` on every `ChildBoard` returned by
  `communicator_child_boards`. If a `ChildBoard`'s `child_account` had been
  deleted (account teardown leaves an orphan; `original_child_boards` is
  `dependent: :nullify`), a single orphaned row raised `NoMethodError` and
  500'd the entire boards index for that owner. `communicator_child_boards`
  now filters out orphaned rows at the source, protecting every serializer.

### Added — admin user page: plan changes, editing, Stripe links, email actions
- The admin dashboard user page (`/admin/users/:id`) can now **change a
  user's plan** (local-only — Stripe is never modified; downgrading to free
  applies full cancellation semantics, `partner_pro` runs full partner
  onboarding, other paid plans also reset `plan_status` to active so
  previously-canceled users aren't auto-reverted).
- New **Edit Account** form: name, email, role, locked, play-demo, and
  manual limit overrides (boards / paid communicators / demo communicators).
- Stripe customer and subscription IDs now **link to the Stripe dashboard**
  in a new tab.
- **Email action buttons**: queue the plan-appropriate welcome email, the
  setup email, or a temporary login link.

### Fixed — Mailchimp tags now land on existing contacts
- `MailchimpService#record_new_subscriber` used to return early when the
  contact already existed in the audience — before applying tags. Since most
  users are synced to Mailchimp at signup, promoting an existing user (e.g.
  to Partner Pro) never applied the "Partner Program" journey trigger tag,
  so they silently never entered the Partner Customer Journey. Tags are now
  applied for existing contacts too, fixing the admin/API partner flows and
  the `partners:backfill_mailchimp_tags` rake task in one place.
- **Demo accounts excluded from admin metrics**: the admin dashboard counts
  and all Mission Control overview/usage metrics now exclude demo/test
  accounts and their activity (boards, word events, communicators, credits,
  AI prompts). The dashboard shows a separate Demo Accounts card linking to
  the demo-filtered user list.
- **Per-user demo cleanup**: demo accounts get a "demo" badge and a Delete
  button on the admin user page — same tombstone path as the Mission Control
  batch cleanup (destroys all content, anonymizes PII, keeps the credit
  ledger). Non-demo and admin accounts can't be deleted from here.
### Added — Keyboard template boards (ABC + QWERTY), unpublished until frontend support ships
- New predefined "ABC Keyboard" and "QWERTY Keyboard" boards
  (`rake keyboard_boards:seed`): 26 letter tiles plus new Space/Delete
  **action tiles** (`board_images.data["tile_type"]`/`["tile_action"]`), the
  first tiles whose behavior is an action instead of a spoken word. Seeded
  `published: false` on purpose — flip to published after the frontend
  keyboard support (letter composition + read-words-as-written play) deploys.

### Fixed — MySpeak onboarding no longer publishes emergency notes as public About Me
- The MySpeak onboarding wizard used to save its care/emergency notes into the
  profile `bio`, which renders publicly as "About Me" on the open page. The
  onboarding endpoint now accepts two separate fields: `about_me` → the public
  bio, and `emergency_notes` → the private, gated `settings["emergency_notes"]`
  (revealed only behind the emergency-info wall and printed on the Safety ID
  card). Legacy clients that still send only `care_notes` now route that text to
  the private emergency notes, not the public bio.
- One-time cleanup for existing data:
  `rake profiles:copy_onboarding_bio_to_emergency_notes` (dry-run by default;
  `DRY_RUN=false` to apply, `USER_ID=N` to scope) copies onboarding bios into
  blank emergency notes while keeping the bio. Frontend pairs with
  itty-bitty-frontend (splits the onboarding step and adds an About Me editor).
### Fixed — boards assigned to communicators now show it everywhere
- Board Builder boards live directly on the communicator (`ChildBoard` with
  no `original_board_id`), but every "who has this board" surface only read
  the clone-source path — so the Board View page's In-use info, the
  Assign-to-communicator popup's "Already has this board" state, and the
  boards-list `in_use_by` label were all empty for built sets. All of them
  (including `ChildAccount#index_api_view`'s `communicator_board_ids`) now
  read both join paths.
- `Board.in_use` stays accurate: `ChildBoard` create/destroy now refreshes
  the flag on the attached board and the clone source (the builder attaches
  the root after the board's last save, so the save-time hook never saw it),
  and a nil-id guard stops brand-new boards from being marked in-use by
  unrelated direct-attach rows. Backfill for existing data:
  `rake boards:recalculate_in_use` (dry-run by default; `DRY_RUN=false`).

### Added — `public_url` on the communicator index payload
- `ChildAccount#index_api_view` now includes `public_url` (the canonical
  slug-based MySpeak URL, e.g. `/my/s-8bdsv4`). The user payload's
  `communicator_accounts` use this lighter serializer, so the frontend
  dashboards previously had no `public_url` and fell back to a
  `/my/<username>` link that doesn't resolve. Now they show the same link as
  the full `api_view` / ViewCommunicator screen. Frontend pairs with
  itty-bitty-frontend (drops the username fallback).

### Added — Board Builder "replace existing set" option
- Re-running the Board Builder for a communicator that already has a built
  set can now **replace** it (`replace=true`): the old set — root and all
  its hidden sub-boards — is removed before the new one builds, instead of
  silently stacking a second full set. "Build another" (`confirm=true`)
  still works as before. Replacing also works for users at their board-set
  limit, since removing the old set frees the slot.
- A board can no longer appear twice on the same communicator dashboard
  (duplicate entries cleaned up and blocked going forward).

### Changed — boards assigned to a communicator are now fully independent copies
- Assigning a board to a communicator now copies its linked sub-boards too
  and points the folder buttons at the copies. Previously only the top
  board was copied, so folder buttons kept opening the original owner's
  live sub-boards — edits or deletions by the original owner would change
  or break the communicator's board.
- Removing such a board from the dashboard cleans up its now-unused
  sub-board copies (unless something else still references them).
- Each communicator's dashboard now has a sanity cap on assigned boards
  (default 80, matching the favorites cap).

### Changed — deleting a board now warns when it's still in use
- Deleting a board that other boards' folder buttons open, that sits on a
  communicator's dashboard, that's shared with a team, or that is a Board
  Builder set root now returns a **409 `board_in_use`** with a summary of
  what references it; re-send with `confirm=true` to delete anyway. Boards
  nothing references delete in one step, unchanged.
- Confirmed deletion of a Board Builder **root** now removes the whole built
  set (root + hidden sub-boards) instead of orphaning the sub-boards.
- Deleting a board now also cleans up references it used to leave behind:
  the free-plan editable-board pick, saved phrase/dynamic board pointers on
  users and communicators, and scenarios generated from the board.
- Removing a board from a communicator dashboard no longer hard-deletes a
  template clone that another board's folder button still opens — it
  detaches only.

### Added — user-picked image budget for menu boards
- Building a board from a menu photo now has a real cost model: the flat
  `menu_create` fee (5 credits) covers the vision extraction, plus **3 credits
  per AI-generated image** (matching standalone image generation) up to an image budget the user picks (`token_limit`,
  default 10, clamped to `MENU_MAX_IMAGES`, default 30). Previously the number
  of generated images was unbounded — every novel item on the menu triggered a
  paid OpenAI call for a flat 5 credits.
- Every menu item still lands on the board: tiles beyond the budget reuse
  existing art or stay blank (`status: "skipped"`), they just aren't sent for
  paid generation.
- Unused budget is refunded automatically (items that reused library art, menus
  with fewer novel items than the budget, per-image generation failures, and a
  full refund — flat fee included — when extraction fails entirely).
- `POST /api/menus/:id/rerun` is now owner-gated (403 for non-owners) and
  credit-gated like a fresh create; it was previously free and open to any
  signed-in user.

### Added — MySpeak page themes (backend) (#476)
- Communicator MySpeak safety pages (`/my/<slug>`) can now carry an owner-picked
  visual theme, stored on `profile.settings["theme"]`. `"theme"` is whitelisted
  into `Profile::SAFETY_PAGE_KEYS`, so it flows through `#safety_view` onto the
  public payload (`GET /api/profiles/public/:slug`). A `before_save`
  sanitizer validates it server-side — hex fields (`accent`, `bg_color`,
  `border_color`, `text_color`) must be `#RRGGBB`, `preset`/`bg_style` must be
  simple slugs, and everything else is dropped — because the values render into
  inline CSS on an unauthenticated page (CSS-injection defense). No migration, no
  new endpoints; the theme round-trips through the existing owner-gated
  `PATCH /api/profiles/:id`. Ships silently until the frontend picker lands.
### Performance — Redis-backed production cache store (#474)
- Production `Rails.cache` now uses a **Redis cache store** instead of Rails'
  default `:file_store` (which was per-box and grew unbounded under `tmp/cache`
  — a real risk on the single EC2 box). Uses the Redis that already backs
  Sidekiq / Rack::Attack, namespaced `ibb_cache` so keys can't collide, with a
  fail-open error handler (a Redis blip logs and returns nil rather than 500ing
  a request). `CACHE_REDIS_URL` optionally points the cache at a separate
  Redis/db (defaults to `REDIS_URL`). No user-facing behavior change; caching
  is simply faster and shared across the puma + sidekiq processes.

### Fixed — AAC Classroom Kit QR codes wouldn't scan
- The kit's name/safety/device backpack tags encoded the ~119-char
  `/classroom?utm_...` funnel URL, which forced a dense 41-module (version-6) QR;
  at the tags' small printed size the modules fell at/below the phone-camera
  detection floor, so the codes **wouldn't scan at all**. The tag QRs now target
  the short `speakanyway.com/myspeak` funnel URL (no UTM) — a ~25-module
  (version-2) code, roughly double the printed module size — and
  `Marketing::SheetRendering#qr_data_url` now runs ECC level `:m` (restored from
  the `:l` hack that only existed to fit the long URL). `NameTagSheet` now shares
  the single `SheetRendering` QR renderer instead of a drift-prone copy.
  `spec/services/marketing/qr_scannability_spec.rb` guards both the ECC level and
  the resulting module density so a long UTM URL can't silently re-break scanning.
### Security — upgrade Rails 7.1 (EOL) → 8.0 (#56)
- Bumped Rails from `~> 7.1.2` (EOL 2025-10-01, no security backports) to
  `~> 8.0.0` (locked 8.0.5). Resolves **CVE-2026-33658** (ActiveStorage DoS via
  proxy-mode multi-range requests, fixed in ≥ 7.2.3.1) and clears Brakeman's
  high-confidence `EOLRails` unmaintained-dependency warning.
- Moved framework defaults to `config.load_defaults 8.0`; the new defaults are
  documented (with revert escape hatches) in
  `config/initializers/new_framework_defaults_7_2.rb` and `_8_0.rb`.
- Replaced the retired, Rails-8-incompatible `annotate` gem with `annotaterb`
  (dev/test tooling only — no runtime/production impact).
- Removed the now-obsolete `EOLRails` entry from `config/brakeman.ignore`.
- No user-facing behavior change; full RSpec suite passes on 8.0.

### Added — rate limiting on auth, token-lookup, and AI-generation routes (#30)
- Rack::Attack now throttles the abuse-prone surfaces that previously had no
  per-IP / per-user limits: **sign-in** (`POST /users/sign_in`,
  `/api/v1/users/sign_in`, `/api/v1/child_accounts/login` — per IP and per
  email), **password reset** (`forgot_password`/`reset_password*` — per IP),
  **access-granting token lookups** (`/api/temp-login/:token`,
  `/api/communicator_claims/:token` — per IP), and the **AI / audio generation**
  routes (`/api/*/generate*`, `generate_audio`, `regenerate_images`,
  `generate_preview_image`, board generation — per user, on top of the existing
  credit-balance gate). Throttled requests get a clean **429** with a
  `Retry-After` header and a generic `{ "error": "rate_limited" }` body (no
  internals leaked).
- Scoped to WRITE/auth/AI-generation abuse only — the AAC read, board-load, and
  **audio-playback** paths a nonspeaking user relies on are never throttled. The
  `/up` health check is safelisted so BetterStack monitoring isn't rate-limited.
- All limits are ENV-tunable (`RACK_ATTACK_LOGIN_LIMIT`,
  `RACK_ATTACK_LOGIN_EMAIL_LIMIT`, `RACK_ATTACK_AI_LIMIT`,
  `RACK_ATTACK_TOKEN_LIMIT`, `RACK_ATTACK_PASSWORD_RESET_LIMIT`, and matching
  `_PERIOD` vars) with sensible defaults. Rack::Attack counts against Redis
  directly (not `Rails.cache`), so throttling works regardless of the cache
  store. **Adds the `rack-attack` gem.**
### Security — scope API resource lookups to the caller (IDOR, issue #26)
- Several `API::Images`, `API::BoardImages`, and `API::Boards` endpoints loaded
  a record with a bare `Image.find` / `BoardImage.find(params[:id])` before any
  ownership check, so an authenticated user could act on **another user's**
  private image or board tile by guessing its id. Lookups are now scoped:
  image endpoints resolve **the caller's own image or a public library image**
  (a non-owner asking for someone else's *private* image gets a 404), while
  destructive/owner-only endpoints (`destroy_audio`, board-image
  edit/variation/audio/update/delete) resolve **only the caller's own** record.
  Admins keep cross-user access; the public/unauthenticated AAC audio path and
  the admin-only merge stay intentionally unscoped. The shared image library
  remains fully usable — only cross-user access to *private* records is closed.

### Fixed — label-only tiles now render as text in PDF export and board previews
- Board PDF exports and the board cover/preview image showed a **picture** on
  label-only tiles (e.g. an "I feel" header) even though the app renders them as
  plain text. The print/preview pipeline resolved each tile's image via
  `BoardImage#tile_image_url`, whose final fallback **borrows any same-label
  public/admin image's art**, fabricating a picture the tile doesn't have.
  `Boards::BoardPdfLayoutNormalizer` now resolves the picture the same way the
  live board JSON does (`display_image_url → image.display_image_url →
  image.src_url`, no label borrowing), so label-only tiles come through blank
  and render as the label text — matching what users see on screen. The shared
  `print` and marketing `print_marketing` templates also drop the now-redundant
  caption beneath a label-only tile (the placeholder already shows the label).
  `BoardImage#tile_image_url` itself is unchanged — its label-match fallback is
  still used by Board Builder folder covers and OBF export.

### Added — stable slugs + marketing print style for the AAC Classroom Kit
- The internal boards API (`POST /api/internal/boards` and
  `POST /api/internal/boards/from_vocab_set`) gains opt-in
  **`replace_existing_slug`** semantics: when set, a previous board holding the
  requested slug is destroyed and the new board takes the exact slug — but only
  when the previous board is owned by the internal admin **and** tagged
  `marketing`. Anything else is left alone (the new board gets a suffixed slug
  instead). `from_vocab_set` accepts the new-board slug as **`board_slug`**
  (`slug` there is the vocab-set key). This keeps the printed kit's QR targets
  (`/pb/<slug>`) stable across kit regenerations and stops `MKT —` scratch
  boards accumulating.
- The internal board PDF export (`GET /api/internal/boards/:id/export.pdf`)
  gains an opt-in **`style=marketing`** param that renders a marketing-branded
  template/layout pair (`api/boards/print_marketing` + `pdf_marketing`):
  gradient header band, white QR chip, footer CTA. **The default (no param) is
  byte-identical to before** — the shared `print`/`pdf` pair used for real
  users' board exports is untouched (spec-guarded).
- The marketing tag/name-tag sheets get a slim "print at 100% · cut along the
  dashed lines" hint strip and a unified brand gradient.

### Fixed — kit tag QR codes were too dense to scan
- The Communication ID (safety), device, and name-tag sheet QRs **didn't
  register as QR codes on phones at all**: rqrcode's default ECC level (`:h`)
  turned the ~119-char `/classroom` UTM URL into a 57-module QR, which at the
  tags' printed sizes was ~0.31–0.45mm per module — below the ~0.5mm
  phone-camera detection floor. (The board poster QR scanned fine because its
  `/pb/<slug>` payload is much shorter.) Fixed by encoding at ECC `:l`
  (41 modules — a clean printed lead magnet doesn't need 30% damage
  redundancy), rendering a 480px print-resolution source PNG, and enlarging
  the printed QR boxes (safety 0.92→1.15in, device 1.15→1.3in, name tag
  20→26mm), putting every tag at ~0.53–0.67mm per module. Verified by
  rasterizing the rendered sheets and machine-decoding: before, no QR decoded
  below 150dpi; after, all three decode at 72dpi. Regression spec pins the
  ECC level + source size.

### Added — reliable server-side `checkout_started` analytics
- Fire a server-side PostHog `checkout_started` when a Stripe Checkout Session
  is created (subscription + top-up), keyed to the user's distinct_id
  (itty_bitty_boards#452 / frontend #505). The browser event was routinely
  dropped when the page unloads to Stripe before PostHog flushes, so the
  `CTA → checkout_started → checkout_completed` funnel read zero; the reliable
  capture is now on the backend. Carries `plan` / `billing_interval` / `source`
  / `kind`, and threads `client_reference_id = user.id` + `source` into the
  Checkout Session so Stripe-originated events attribute to the same person.
  Instrumentation only — no user-facing behavior change.

### Added — compact backpack safety + device tags for the AAC Classroom Kit
- New `GET /api/internal/marketing_artifacts/safety_tag.pdf` and
  `.../device_tag.pdf` render generic, print-and-cut **backpack ID tags**
  (`Marketing::SafetyTagSheet` / `Marketing::DeviceTagSheet`) — compact,
  fixed physical size, laid 2-up on a single Letter page with cut lines, QR to
  the `/classroom` funnel. These replace the kit's previous use of the app's
  detailed Profile safety card, which is a full page and overflowed onto a
  second page when exported (the card canvas is taller than A4). The kit's tags
  no longer depend on a sample Profile. The app's Profile-driven safety card
  (`Communicators::GenerateSafetyIdCard`) is unchanged.

### Added — host the AAC Classroom Kit (free marketing lead magnet)
- New `MarketingAsset` model + `POST /api/internal/marketing_assets` and
  `GET /api/internal/marketing_assets/:slug` (behind `INTERNAL_API_KEY`) host a
  print-ready marketing PDF (the assembled AAC Classroom Kit) at a stable public
  slug. The file is attached at a deterministic S3 key
  (`marketing_assets/<slug>.pdf`) with purge-then-reupload, so the public CDN
  URL never changes across regenerations — the kit build is idempotent and the
  URL is safe to drop into the `/classroom` page's `KIT_DOWNLOAD_URL`. Not a
  sellable product; never published to any marketplace.
- New `GET /api/internal/marketing_artifacts/name_tag.pdf` renders a generic,
  fillable classroom name-tag sheet (variant A — no per-child data) N-up on a
  Letter page via Grover, with a shared QR pointed at `qr_target_url`.
- The per-communicator asset generators (`Communicators::GenerateSafetyIdCard` /
  `GenerateDeviceTag`) now accept an optional `qr_target_url:` so the kit's
  sample safety + device tags point their QR at the `/classroom` funnel instead
  of the sample MySpeak page. Default behavior (QR → the profile's public page)
  is unchanged. The internal profiles `PATCH` accepts a `qr_target_url` to drive
  this regeneration.
- New `bin/rails marketing:seed_kit_sample_profile` seeds one admin-owned,
  clearly-generic sample safety profile so the kit renders realistic sample tags
  without touching any real child's data (idempotent).

### Added — internal API endpoint to create a board from a curated vocab set
- New `POST /api/internal/boards/from_vocab_set` (behind `INTERNAL_API_KEY`)
  clones the ROOT grid of a curated Board Builder vocab set (`core-60` /
  `core-84`) into a fresh admin-owned board and returns it as JSON (`201`), so an
  internal caller (the printables marketing generator) can source a poster from
  vetted core vocabulary and immediately export it to PDF. v1 clones only the
  root grid, not the linked fringe tree. Returns `404 vocab_set_not_seeded` when
  the requested set isn't seeded in the environment (no `500`). Additive — no
  migration, no new ENV var, and `create`/`update`/`show`/`export` are unchanged.

### Added — new-subscriber onboarding email when a paid plan starts
- New Mailchimp `subscription_started` Customer Journey fires when a user
  converts to an active paid plan (the non-active→active transition in the
  Stripe subscription webhook) — the marketing counterpart to the transactional
  plan welcome, so paid subscribers get a warm "get the most out of your plan"
  nurture (the existing `welcome` journey is Free-flavored). Fires once per
  conversion; renewals don't re-trigger.
- Inert until configured: no-ops until `MAILCHIMP_JOURNEY_SUBSCRIPTION_STARTED_ID`
  / `_STEP` are set, and journeys stay prod-only by default
  (`MAILCHIMP_JOURNEYS_ENABLED=true` to override in staging/dev). Fires for both
  **web (Stripe)** and **mobile (RevenueCat/Apple IAP)** conversions, so paid
  subscribers on either platform get the email. All 6 prior journey keys plus
  this one are now mirrored into the staging env-sync templates.
### Fixed — Partner Pro accounts now get full Pro credits + permissions immediately
- Partner Pro signups were landing with the Free credit allowance (e.g. 25 AI
  credits) instead of the Pro allowance (1,500), because credits were granted
  while the account was still Free (before it was flipped to `partner_pro`) and
  never re-granted. Partner signups now receive the Pro credit allowance
  **immediately at signup** — no waiting on a background job.
- Partner Pro is now treated as a Pro-equivalent tier everywhere: `pro?` returns
  true for it, so partners get Pro permissions (paid-plan gates, 5 supporter
  seats, communicator lending/hand-off, unlimited MySpeak IDs) to match their
  already-Pro board/communicator limits. Previously partners were silently
  treated as Free on those permission checks.
- Backfill for existing partners stuck on the Free allowance:
  `rake partners:grant_pro_credits` (dry-run by default; `DRY_RUN=false` to apply).

### Added — Partner Pro pilot expiry reminders (no auto-downgrade)
- The 3-month Partner Pro pilot's end date (`plan_expires_at`) was previously
  set but never acted on, so partners kept Pro-level access indefinitely with no
  reminder. New `PartnerPilotEndingJob` (daily) now emails partners a friendly
  "your pilot is wrapping up" heads-up ~14 days before their end date and emails
  the SpeakAnyWay admin a digest of partners ending soon / newly ended.
- **Nothing is auto-downgraded** — partners keep their boards and access; the
  digest is a prompt to convert, extend, or downgrade each partner by hand.
  `rake partners:pilot_status` lists pilots by status on demand. Lead time is
  tunable via `PARTNER_PILOT_REMINDER_LEAD_DAYS` (default 14).

### Added — owner picks which communicators stay signable on downgrade (#439)
- When a user is over their plan's communicator slot limit after a downgrade,
  the over-limit accounts enter fallback mode (private sign-in paused; public
  MySpeak page + boards stay open). Previously the system auto-kept whichever
  communicators signed in most recently. Now the **owner chooses** which ones
  stay full, mirroring the board "make this one editable" pick.
- New `POST /api/child_accounts/keep_signable` `{ communicator_ids: [...] }`
  persists the owner's pick (owner-owned ids only, capped at the slot limit) and
  re-reconciles immediately; the chosen ids keep private sign-in, the rest fall
  back. `User#reconcile_communicator_fallback!` now orders **owner-pinned first,
  then most-recently-active**. `communicator_slot_limit` and
  `kept_communicator_ids` are exposed on the user `api_view` for the picker UI.
  No access or boards are ever removed — only which accounts can sign in
  privately changes.

### Added — free board PDF downloads for anonymous visitors (lead capture)
- `GET /api/free_download_boards` (public, no auth) lists the curated public
  board gallery (`Board.public_boards` — admin-owned, predefined + published)
  with `id`, `name`, `description`, and `image_url` for an anonymous
  lead-capture page. No new board flag — the existing public gallery is the
  offered set.
- `POST /api/download_leads` (public, no auth) captures a visitor's email (with
  optional name, board_id, source, and data) as a `DownloadLead`, returns
  `201 { success: true }`, and enqueues `MailchimpUpsertLeadJob` to sync the
  email to Mailchimp as a `BoardDownloadLead`. Invalid/missing emails return
  `422 { success: false, errors: [...] }`. The existing
  `GET /api/boards/:id/pdf` continues to serve the file unchanged.
- Admin **Mission Control** now has a **Download Leads** panel: leads captured
  today / 7d / 30d, unique emails (7d), all-time total, and Mailchimp sync
  health (synced / pending / failed, with the failed count flagged red) plus a
  by-source breakdown — so a stalled Mailchimp sync is visible at a glance.

### Fixed — clearer plan-change errors when there's no payment method
- `POST /api/subscriptions/change_plan` now returns a distinct, actionable
  **402 `payment_method_required`** (with a message pointing to the billing
  portal) when a switch fails because the customer has no payment method on
  file — instead of the generic `400 "Failed to change plan"` that gave the
  frontend nothing to act on. Card declines still return `402 payment_failed`;
  other Stripe errors still return the generic 400.
- `POST /api/subscriptions/preview_plan_change` now returns a
  `payment_method_required` boolean — true only when the switch bills the
  customer today (`amount_due > 0`) **and** there's no payment method on file —
  so the confirm modal can prompt for a card up front instead of letting the
  user hit a Confirm that can only fail. Credit-only downgrades aren't flagged.

### Added — boards now lay out well on phones and tablets, not just large screens
- Medium/small column counts are now **derived proportionally** from a board's
  authored large-screen count (`Boards::ScreenColumns`: md ≈ ⅔ of lg, sm ≈ ⅓ of
  lg, with a 2-column floor for phones) instead of fixed defaults that ignored
  how dense the board was. New boards get these automatically.
- The medium/small **tile layouts** are now reflowed from the large layout with
  a width-aware packer (`Boards::ScreenReflow`) so multi-width tiles never
  overflow the narrower grids — every tile stays on the board (nothing dropped),
  read in the authored large-screen order. Editing the large layout regenerates
  md/sm to match; a screen the user hand-arranges is marked in
  `settings["custom_screen_layouts"]` and left untouched. Board Builder sets
  reflow the whole tree at build time.
- Backfill existing boards with `rake board_layouts:reflow_sm_md` (dry-run by
  default; `DRY_RUN=false` to apply, `USER_ID=N` to scope, `KEEP_COLUMNS=true`
  to reflow without changing column counts). The large layout is never touched.

### Fixed — builder boards rendered differently in Speak vs. the editor
- Board Builder sets (e.g. Core 84) could carry duplicate tiles and folder tiles
  pushed **past** the grid edge (x=13 on a 12-column board). The editor clamped
  to the configured columns, but the Speak/dynamic view widened the grid to fit
  them — so the same board looked different in Speak. `Boards::TileDeduper` now
  keeps the **in-grid** copy of a duplicate, and a new `Boards::LayoutRepacker`
  pulls any remaining out-of-grid tiles back inside the grid. Run
  `rake board_builder:repair_grid` (dry-run by default; `DRY_RUN=false` to apply)
  to clean existing seed sources and built sets.

### Fixed — Board Builder sets now classify correctly on the boards list
- A built board set's **home board** now shows up under **"In use"** and
  **"Main boards"** like any other assigned board. Previously the builder
  attached the home board to the communicator in a way nothing else did, so it
  never registered as "in use" and got lost on the boards list.
- The set's **sub-pages** (Food, Feelings, category folders, etc.) are now
  correctly classified as **sub-boards** instead of leaking into the main
  boards list, so the list shows the set's home board rather than every page.
- Built sub-pages are now **frozen** by default: tapping a word on a sub-page no
  longer auto-returns to the home board, so a child can keep making selections
  on the page. (Still adjustable per board in the editor.)
- Existing built sets can be brought in line with
  `rake board_builder:reclassify_builder_sets` (dry-run by default).
- The home board now **stays** a main board even though its sub-pages each carry
  a "Home" tile that links back to it. Previously those back-links re-classified
  the home board as a sub-board on a later save, dropping it off the boards list
  again; `Board#check_is_sub_board` now pins any builder home board as a main
  board regardless.

### Fixed — Core 84 / Core 60 missing tiles ("84 only shows 82")
- A built core set could render with fewer tiles than authored because two tiles
  ended up stacked on the **same grid cell** (one hidden behind the other) while
  another cell sat empty — a leftover from an earlier seeding bug. A clean
  first-time seed was always correct; this only affected sources mangled by past
  re-seeds.
- `bin/rails vocab_sets:seed` is now **self-healing**: it re-pins every tile to
  its authored grid position from the source, so one re-seed restores a clean
  84/60 with no overlapping tiles.
- For sets already built from a corrupted source, `Boards::LayoutRepacker` (and
  thus `rake board_builder:repair_grid`) now also un-stacks **overlapping**
  tiles, not just off-grid ones — no tile is lost; the displaced one moves to a
  free cell.

### Fixed — board preview thumbnails (wrong/stale + missing)
- Board grid thumbnails now reliably reflect the board's **current** contents.
  `Board#display_image_url` (what the grid reads first) resolves with a clear
  precedence: an explicit user-uploaded cover wins, otherwise the **live**
  auto-generated preview wins, and the denormalized `display_image_url` column
  is only a seed thumbnail used before the first preview exists. Previously the
  live preview was used only when an opt-in `display_follows_preview` flag was
  set, so most boards showed a frozen snapshot that never refreshed after edits.
- `Board#preset_display_image_url` now tracks the live preview instead of a
  frozen `settings` snapshot string, so it can't go stale while a preview
  exists (the snapshot is kept only as a legacy backstop and is refreshed to the
  current preview URL on every generation).
- Preview generation writes the refreshed display URL **atomically** inside
  `Boards::GeneratePreviewAssets`, removing the post-job reload/write race that
  could briefly serve a stale URL, and ensuring synchronous generation paths
  keep the snapshot fresh too. Genuine Grover render failures now propagate so
  the job actually retries instead of silently "succeeding" with no thumbnail.
- Removed the unused 2-minute-delayed `Board#run_generate_preview_job_later`.
### Fixed — Board Builder no longer makes a whole board for a single interest
- A lone interest word (e.g. "backpack") whose category isn't a seed or prebuilt
  page for the chosen level used to spin up an entire AI-generated board named
  after that one word. Now an AI page is only created when its category has at
  least `BOARD_BUILDER_MIN_AI_PAGE_INTERESTS` interests (default 2). A sparse
  interest is placed on an existing matching board in the set when one exists
  (e.g. a category folder already present), and otherwise lands in My Favorites
  — never its own board. Cuts spurious single-word boards and saves AI credits.

## [1.2.1] — 2026-06-23

### Changed — Board Builder mutes folder/dynamic tile names
- Tiles in a built board set that open another board (folder / dynamic tiles,
  `predictive_board_id` set) now default to `mute_name: true`, so tapping a
  folder navigates without speaking the folder's own label. Word tiles are
  unchanged. Applied across the whole built set (root + sub-boards) by
  `BuildBoardSetJob`.

### Fixed — Board Builder "extra all done" duplicate tile
- Built board sets (Core 60/84) no longer show a duplicate `all done` tile (and
  any other duplicated word tile). Root cause: `Board.from_obf` keyed its tile
  upsert on the resolved `image_id`, so a re-seed that resolved the same
  authored button to a different `Image` appended a second tile instead of
  updating the existing one; `SeededSetCloner` then copied it into every set
  built since the bad re-seed. The upsert is now keyed on the stable OBF button
  id, and the `vocab_sets:seed` sync pass collapses any duplicate it finds
  (`Boards::TileDeduper`).
- `rake board_builder:dedupe_seed_tiles` (dry-run by default; `DRY_RUN=false` to
  apply, `USER_ID=N` to scope) removes the duplicate from the seed sources and
  from already-built user sets.

### Added — AppSignal APM (per-request + host visibility)
- Added the `appsignal` gem and `config/appsignal.yml` to capture per-request
  latency (p95/p99), slow queries/N+1, host CPU/memory/disk, and Sidekiq queue
  latency — Phase 1 of the scaling roadmap (#391 / #390), so later sizing
  decisions are data-driven. Instruments both the Puma web process and the
  Sidekiq worker process automatically; **active in production/staging only**
  (no-op in dev/test). Requires `APPSIGNAL_PUSH_API_KEY` in Hatchbox for both
  apps, plus `APPSIGNAL_APP_ENV=staging` on staging so it reports as a distinct
  environment (both run `RAILS_ENV=production` on the shared box). `/up` health
  pings are excluded from metrics; secrets/PII are filtered from traces.

### Changed — Safety info (and its parent alert) is now behind the Emergency Info action
- The public MySpeak page (`GET /api/profiles/public/:slug`) is the everyday
  social surface and **no longer ships medical info or emergency contacts** —
  those keys (`allergies`, `medical_conditions`, `medications`,
  `other_conditions`, `other_conditions_notes`, `emergency_notes`,
  `emergency_contacts`, `ice_contact_*`) are withheld from the page payload.
  Only page-safe settings (`pronouns`, `device_notes`) plus a `has_safety_info`
  boolean come down on load.
- The sensitive data is revealed only by the new gated endpoint
  `POST /api/profiles/public/:slug/safety_view`, which is also the **single
  place that records the access and (throttled, ≤1 email/hour) alerts the
  parent**. Opening the page no longer logs a view or notifies anyone — only a
  deliberate "Emergency Info" open does. Every reveal is still recorded in
  `profile_views` for the audit trail; only the email is throttled. Parent-alert
  email copy updated from "safety page was viewed" to "emergency info was
  opened" (en + es). Issue #384 follow-up.
### Fixed — Removing a hand-off board no longer deletes it
- After a communicator is transferred, the new owner can clear/curate the
  dashboard without losing boards. On hand-off, the communicator's boards are
  registered as **team boards**, and "remove from dashboard" (`DELETE
  /api/child_boards/:id`) now **detaches** the board instead of deleting it —
  it stays available via the team to re-add. The board is only hard-deleted when
  it's a throwaway template clone that nothing else references. Dashboard board
  entries also expose a `can_remove` flag (keyed to communicator ownership) so
  the new owner sees the remove control. `rake communicators:repair_handoff_teams`
  backfills the team-board safety net for already-claimed communicators.

### Fixed — Communicator hand-off now updates the right team
- When a family claimed a loaned communicator, the new owner was sometimes added
  to the wrong team (the communicator's *own* team was left with only the
  previous owner). `ChildAccount#claim_by!` now resolves the communicator's own
  team deterministically instead of using `teams.first`, adds the new owner as
  **admin**, keeps the previous owner as **supervisor**, and **transfers team
  ownership** to the new owner so they can manage the team. Existing accounts can
  be repaired with `rake communicators:repair_handoff_teams` (dry-run by
  default).

### Changed — Lending a communicator is enforced as Pro-only
- The `lend` and `promote_to_loaner` endpoints now return **HTTP 403
  `pro_required`** for non-Pro callers (admins bypass), matching the frontend's
  existing Pro-only "Lend to a family" controls. Closes a gap where a Basic user
  — or a direct API call — could lend a communicator.

### Changed — New MySpeak communicators get an unguessable safety slug
- MySpeak onboarding (`POST /api/v1/onboarding/myspeak`) no longer creates a
  name-derived public slug. The safety profile now gets a random `s-xxxxxx`
  slug (via `Profile#ensure_slug`), so a child's public emergency page can't be
  found by guessing their name. The account's **username** stays readable. Any
  client-supplied `slug` is ignored — random is enforced server-side. Completes
  the random-slug work from the prior release for *new* signups (the "Pick your
  link" wizard step is being removed in the frontend).

### Fixed — Mailchimp journey triggers can't flood the Sidekiq dead set
- `MailchimpService#trigger_journey` resolves the gem's Customer Journeys
  accessor defensively (camelCase `customerJourneys`, falling back to snake_case
  only if a future gem adds it) and now **catches/​logs/​swallows a
  `NoMethodError`** instead of letting it crash `MailchimpEventJob`. Previously a
  gem-shape mismatch raised on every trigger, exhausted the job's retries, and
  piled hundreds of jobs into the Sidekiq dead set. `ApiError` 404-retry
  behavior is unchanged.

### Fixed — User settings hardening & cleanup
- The `PUT /api/users/:id/update_settings` endpoint now only persists a
  whitelist of real preference keys (voice, display toggles, board pointers,
  etc.) and requires the caller to be the account owner or an admin. Previously
  it wrote **every** request parameter into the settings blob (leaking Rails'
  `controller`/`action`/`id`/`format`) and performed no ownership check.
- Removed the dead `ai_monthly_limit` plan-limit setting and the unused
  monthly AI action-counter (`MonthlyFeatureLimiter`, `ai_limit_reached?`).
  AI has been gated by the credit ledger for a while; this setting was written
  but never read on the enforcement path.
- Added `rake settings:cleanup` (dry-run by default; `DRY_RUN=false` to apply,
  `USER_ID=N` to scope) to scrub the leaked junk keys and the dead
  `ai_monthly_limit` key from existing users' settings.

### Added — Random, unguessable slugs for safety profiles
- A communicator's public safety page (`/my/<slug>`) now uses an unguessable
  random slug (`s-` + 6 unambiguous characters, e.g. `s-k8x2mf`) instead of a
  name-derived one, so a child's emergency page can't be found by guessing
  their name. Only safety profiles are affected — vendor/SLP/user pages keep
  readable slugs.
- Existing safety profiles migrate via `rake profiles:migrate_to_random_slugs`
  (dry-run by default; `DRY_RUN=false` to apply, `USER_ID=N` to scope), which
  preserves the old slug as `legacy_slug`. The public endpoint
  (`GET /api/profiles/public/:slug`) 301-redirects an old legacy slug to the
  current random slug, so printed cards, bookmarks, and shared links keep
  working.
- The migration enqueues `RegenerateSafetyCardsJob` per profile to rebuild the
  safety ID card + device tag (new QR code) and email the parent that fresh
  cards are ready to download. Random slugs are not user-editable.

### Added — Parents are alerted when their child's safety page is viewed (#384)
- When someone opens a public safety (MySpeak) profile page
  (`GET /api/profiles/public/:slug`), the parent now gets an email letting them
  know their child's emergency info was accessed, with the timestamp and an
  approximate (city-level) location of the viewer. Zero friction for the
  viewer — no login, no gate.
- Every public safety-page view is logged to a new `profile_views` table
  (IP + user agent + timestamp) so unexpected access patterns are visible.
- Alerts are **on by default** and throttled to **at most one per profile per
  hour** so a parent checking their own page isn't spammed. A parent can turn
  them off per-profile via `settings["view_alerts_enabled"] = false`
  (surfaced as `view_alerts_enabled` on the profile `api_view`), and the global
  `settings["disable_notifications"]` flag is also respected.
- Backend-only; no frontend changes required. All work (geolocation, throttle,
  email) runs in `RecordProfileViewJob` so the public emergency page is never
  slowed or broken by it. Email is the v1 channel; a push channel is stubbed in
  `Notifications::SafetyViewNotifier` for when device-token infra lands.
- Coarse IP→location uses the new `geocoder` gem (provider/key ENV-tunable:
  `GEOCODER_IP_LOOKUP`, `IPINFO_API_KEY`); location is simply omitted if the
  lookup is unconfigured or fails.

### Changed — Screenshot board import commits faster (deferred AAC categorization)
- Committing a board imported from a screenshot
  (`POST /api/board_screenshot_imports/:id/commit`) created a new `Image` for
  every tile label with no existing match. Each novel label triggered a
  **synchronous OpenAI call** inside the commit transaction (via
  `Image#ensure_defaults` → `AacWordCategorizer.categorize`), adding latency and
  cost to a user-facing action. `ensure_defaults` now honors the existing
  `skip_categorize` / `do_not_categorize?` flag: such images get sensible
  neutral defaults immediately (part_of_speech `default`, gray colors) and the
  real categorization is finished off-thread by the new `CategorizeImageJob`
  after commit, so tiles still get correct AAC colors/POS shortly after. Normal
  image creation (no `skip_categorize`) is unchanged. Specs added in
  `spec/services/board_from_screenshot_spec.rb` and
  `spec/sidekiq/categorize_image_job_spec.rb`.

### Fixed — Board Builder "Extended" no longer produces an over-full board
- An **Extended** Board Builder set built on a fuller Core 84 grid (e.g. one
  carrying the new Phrases layer with fewer reserved empty cells) could exceed
  the authored 7×12 (84-cell) grid, spilling tiles onto a stray extra row — the
  reported **86 tiles instead of 84**. The grid cap is now a hard guarantee:
  the grid math lives in one place (`Board#open_grid_cells`) and **every**
  top-level tile-adder honors it — the "My Favorites" catch-all in both
  `BuildBoardSetJob` and `SeededSetCloner`, plus the existing Phrases folder and
  quick-phrase strip — so a built set never overflows regardless of how little
  slack the seed leaves. Aliased interest categories ("Family & People",
  "Health & Body") now route into the cloned People/Body pages instead of
  spawning a spurious extra "My Favorites" folder. The early-stage quick-phrase
  strip also **dedupes against the home board** so it can't surface a phrase the
  home board already carries — e.g. "all done" is both an authored core word and
  a Transitions gestalt, which previously produced a duplicate "all done" tile.
  Regression coverage added in `spec/sidekiq/build_board_set_job_grid_spec.rb`.

### Fixed — "Make a Board From Screenshot" robustness
- A failed screenshot import now **refunds** the 3 credits charged at upload —
  previously a user whose AI analysis failed was out the credits with nothing to
  show. The refund returns credits to the exact plan/topup split they came from
  and is idempotent across Sidekiq retries.
- Editing detected cells via `PATCH /api/board_screenshot_imports/:id` no longer
  drops `row`/`col` changes (they weren't permitted) and no longer 500s when the
  request omits the `board_screenshot` key.
- Committing an import that isn't ready (still processing/failed) returns a clean
  **422 `import_not_ready`** instead of a raw 500.
- The preprocessed temp image is always cleaned up, even on failure (it was
  leaking into `tmp/` on every import).
- On **staging**, screenshot analysis now returns a deterministic placeholder
  grid instead of calling paid OpenAI vision — mirroring the existing
  image-generation placeholder, so QA doesn't incur API cost or burn credits.

### Fixed — Sandbox communicators no longer advertise a sign-in
- A **sandbox** (no-login demo) communicator owned by a paid or free-trial user
  was returning `can_sign_in: true` and a real `startup_url`
  (`/accounts/sign-in?username=…`) in its API payload — even though a sandbox
  has no passcode and cannot be signed into. `ChildAccount#can_sign_in?` now
  short-circuits to `false` for any sandbox (before the admin/plan checks), and
  `ChildAccount#startup_url` returns `nil` for a sandbox, so the contradiction
  no longer reaches the frontend. Active and loaner communicators are
  unchanged. Specs added in `spec/models/child_account_spec.rb`.

### Fixed — Board Builder fringe pages now show tile artwork
- A built board set's **main board** showed pictures on its tiles, but the
  **fringe/category pages** (Food, Feelings, Animals…) often rendered blank. The
  blank→art upgrade only ran on the root board; fringe pages cloned through a
  path with no upgrade. Every cloned fringe page now gets the same upgrade, so
  the whole set renders with images.
- Image resolution now picks the **curated "default" image** — the admin library
  image with the **most artwork attached** — when several images share a label,
  instead of grabbing the lowest-id (often blank) one.
- Existing built sets can be backfilled with the idempotent
  `rake board_builder:upgrade_tile_images` (dry-run by default; `DRY_RUN=false`
  to apply, `USER_ID=N` to scope to one owner).

### Fixed — Paid users' communicators stuck in sandbox mode (#359)
- A communicator created while a user was on the Free plan was forced into
  no-login **sandbox** mode, and upgrading to Basic/Pro never converted it — so
  paying users could be walled off with "Sign-in disabled for Sandbox
  Communicators". Upgrading to **Basic** (which grants no sandbox slots) now
  automatically promotes those leftover sandbox communicators to full **active**
  accounts (with sign-in), up to the plan's slot limit, most-recently-active
  first. **Pro** is left alone — it includes an intentional sandbox/demo slot.
- Existing affected users can be fixed with the idempotent
  `rake communicators:promote_paid_sandboxes` (dry-run by default; `DRY_RUN=false`
  to apply, `USER_ID=N` to scope to one user).

### Added — Gestalt language (GLP) support
- Communicators can now carry an optional **NLA stage** (`glp_stage`, 1–6),
  stored in `child_accounts.details` alongside the existing AAC profile fields
  (`aac_level`/`vocab_type`/`age_band`) — it measures something different, so it
  doesn't replace them. Set it via the existing communicator-update `details`
  param; it's exposed on the communicator `api_view`. Drives gestalt-aware AI
  word-suggestion prompts (whole phrases at early stages → full sentences at
  advanced stages) via `CommunicatorProfile`.
- Six predefined **GLP board templates** of whole-phrase tiles — Greetings &
  Social, Requests & Wants, Protests & Boundaries, Comments & Observations,
  Feelings & Emotions, Transitions & Routines — available on all plans. Seed
  with `bin/rails glp_templates:seed` (idempotent). They surface in
  `GET /api/v1/board_builder/templates` (with `glp_templates` + a stage-aware
  `recommended_template`), and `?template_type=glp` narrows the picker to GLP
  only.
- **Script Collector** support on `POST /api/boards/:id/add_image`: a tile can
  be marked `part_of_speech: "phrase"` (a whole-phrase gestalt tile, no longer
  re-categorized as a single word) and carry free-form `gestalt_source` /
  `utterance_function` metadata, stored on `board_images.data`.

### Fixed — Board Builder: category folder tiles render blank
- Category folder tiles (Animals, People, Feelings, Food…) on a built set now
  show a curated symbol by default instead of a blank tile. Resolution grabbed
  the first image matching the label, which was often a blank, art-less image
  the OBF seed created for that label — even though a curated image with art
  existed. New `Boards::ImageResolver` prefers an art-bearing image (matching
  the label **case-insensitively**, since folder labels are capitalized while
  library art is often lowercase), used by the cloner, blueprint assembler, and
  `BuildBoardSetJob`. The authored/curated folder name ("Animals") is preserved
  as the tile text even when the art image is stored lowercase ("animals").

### Fixed — Board Builder: extra "85th tile" and dead folder tiles on built sets
- A built robust set (e.g. Extended / Core 84) no longer overflows its authored
  grid. The build added one folder tile per fringe page via `Board#add_image`,
  which fills the authored grid's open cells and then spills onto a stray extra
  row — so a 7×12 (84-cell) Core 84 came out with 85+ tiles. The build now caps
  the top-level folder tiles it adds to the open cells on the authored grid and
  folds the remainder into a single "My Favorites" page (nothing the child
  selected is dropped).
- Authored folders are no longer left **dead** (unlinked). The hybrid path used
  to *exclude* "unplanned" seed pages from the clone while leaving their folder
  tiles on the root, so **More / School / Time / Describe** opened nothing when
  tapped. The build now clones the authored core set intact — every folder links
  to a real board.

### Added — Board Builder: complexity levels, AI fringe pages, hybrid build (Phase 2)
- **Complexity levels** replace raw template keys in the wizard: Starter (4-6
  fringe pages), Standard (8-10), Extended (10-15). Legacy `template` param
  still works; new `level` param is the intended path forward.
- `GET /api/v1/board_builder/templates` now returns a `levels` array with key,
  name, description, and fringe_page_range for each level, plus a
  `recommended_level` based on the communicator's stored profile.
- **StructurePlanner** decides which fringe pages to include per level, resolving
  each to one of three sources: `:seed_set` (already in the core clone),
  `:prebuilt` (standalone OBF template), or `:ai_generated` (OpenAI).
- **11 standalone fringe page OBF templates** seeded via
  `bin/rails fringe_templates:seed`: Animals, Art & Craft, Bathroom, Clothing,
  Home, Music, Nature & Outdoors, Social, Sports, Technology, Transportation.
- **AiPageGenerator** service generates niche interest pages via OpenAI when no
  pre-built content exists (e.g., a user's unique hobby). Profile-aware prompts
  tailor vocabulary to the communicator's AAC level and age.
- **`ai_board_page` credit feature key** (cost: 2 credits per AI-generated page).
  Graceful fallback: if the user lacks credits, niche interests route to the
  "My Favorites" catch-all instead of failing.
- `CreditService.can_spend?` — balance check without locking/spending.
- `SeededSetCloner` now supports `exclude_fringe:` to skip seed set pages the
  planner doesn't need for the chosen level.
- Level recommendation heuristics: young/emerging → Starter,
  developing/young-teen → Standard, proficient/older → Extended. **These are
  reasonable defaults, not clinically validated** — revisit with AAC research
  or user data before treating them as authoritative.

### Added — Board Builder: expanded interest categories + categorized picker endpoint
- Expanded interest dictionary from 4 categories (~120 words) to 18 categories
  (~504 words). New categories: Animals, Art & Craft, Clothing, Family & People,
  Health & Body, Home, Music, Nature & Outdoors, Places, School, Social, Sports,
  Technology, Transportation.
- New `GET /api/v1/board_builder/interest_categories` endpoint returns the full
  category dictionary for the frontend's categorized interest picker.
- Interest cap raised from 12 to 20.
- `create` now accepts interests as `[{ word, category }]` hashes for explicit
  routing from the picker (plain strings still work via dictionary lookup).

### Improved — Admin dashboard: light/dark toggle + engagement metrics
- **Light mode default** with a toggle in the top-right nav. Preference persists
  in localStorage. All admin pages (Dashboard, Mission Control, Users) use CSS
  variable theming that works in both modes.
- **New Engagement section** on Mission Control: Active Users (7d), Active Users
  (30d), Trial Users (currently trialing), and Communicator accounts.
- **Signup Trend chart** showing daily signups for the last 7 days as a bar chart.
- All admin views (Dashboard, Mission Control, Users list, User detail) updated
  from hard-coded dark-only colors to CSS-variable theming.

### Added — Expose plan_status and persist Stripe trial_ends_at (#324, #325)
- `User#api_view` now includes `plan_status` so the frontend can distinguish a
  payment-provider trial (`"trialing"`) from an active paid plan.
- Stripe webhook (`handle_subscription_upsert`) persists
  `settings["trial_ends_at"]` (ISO8601) when a subscription is trialing, and
  clears it on conversion or cancellation — matching the RevenueCat path.
  The frontend's trial countdown now works for both web and iOS trials.
- `GET /api/v1/users/current` calls `reconcile_stranded_plan!` so a stale
  plan_status self-heals on the user-fetch path, not only at sign-in.

### Added — Promo-aware one-click plan switch for existing subscribers (#308)
- **`POST /api/subscriptions/change_plan_portal_session`** lets an existing
  subscriber switch plans (e.g. basic-monthly → the yearly Founding rate) with
  the promo pre-applied — no fresh checkout (which would double-bill an active
  sub), no manually typed code. Params: `plan_key` (required), `promo_code`
  (optional). It resolves the plan to a Stripe price (shared `PLAN_PRICE_IDS`),
  looks up the active promotion code the same graceful way checkout does, finds
  the user's own active/trialing/past_due subscription, and opens a Stripe
  Customer-portal **deep link** (`flow_data.subscription_update_confirm`) that
  pre-selects the new price + discount. Stripe renders its own confirm page
  (price change + proration), so we never mutate the subscription directly; the
  resulting `customer.subscription.updated` webhook applies the new entitlements
  exactly like a manual portal switch. Returns 422 when the user has no
  active subscription (those users belong in checkout) or an unknown plan, and
  400 (generic message) on any Stripe error. Frontend wiring lands separately.

### Fixed — Stripe checkout/signup hardening (entitlement bypass + customer linking)
- **`POST /api/stripe/update_user_from_session` could grant a paid plan for an
  unpaid checkout.** It set `plan_type`/`plan_status=active` straight from the
  session's `plan_key` metadata without checking the checkout completed, so
  hitting the success URL with an abandoned/expired session's id flipped the
  user to a paid tier for free. It now requires `session.status == "complete"`,
  only lets the authenticated **owner** of the session reconcile from it (403
  otherwise), and reads the **real subscription status** (`trialing`/`active`)
  so a no-card trial is no longer recorded as `active` (and can't clobber the
  webhook's `trialing`). Credits remain webhook-only.
- **`customer.created` webhook now links the Stripe customer to the user**
  (fills a blank `stripe_customer_id`, never repoints an existing one) instead
  of relying on `email_signup`'s separate save winning the race, and the
  invite-fallback is race-safe (re-finds by email on a unique violation rather
  than duplicating the account).

### Added — iOS/Apple trial-ending reminder email
- New `RevenueCatTrialEndingJob` (daily cron, 5am UTC) sends the "trial wrapping
  up" reminder to RevenueCat trialists ~`REVENUECAT_TRIAL_REMINDER_LEAD_DAYS`
  (default 3) before their trial ends. Apple/RevenueCat send no `trial_will_end`
  webhook (unlike Stripe), so this computes the reminder from the
  `settings["trial_ends_at"]` the webhook persists and enqueues the shared
  `MailchimpTrialWrapJob` (same `trial_wrap` journey + merge fields as web).
  Flags `settings["rc_trial_wrap_sent"]` so each trial is nudged once (re-armed
  when a new trial starts). Keying on `trial_ends_at` scopes it to RC trials, so
  Stripe trialists are never double-nudged. This completes iOS/Stripe trial
  parity.

### Added — RevenueCat (iOS/Apple) free trials are now first-class
- The RevenueCat webhook reads `period_type`: a `TRIAL`/`INTRO`
  `INITIAL_PURCHASE` now marks the user `plan_status="trialing"` (was always
  `active`), persists `settings["trial_ends_at"]`, and fires a distinct
  `trial_started` analytics event (internal + PostHog) instead of
  `subscription_started`. `subscription_started` now fires on **conversion**
  (a normal-period renewal/product-change out of a trial), and an unconverted
  trial `EXPIRATION` is tagged `reason: "trial_expired"` — so iOS trial→paid
  conversion is measurable, matching the Stripe path.
- `BillingController#update_subscription` (the client confirmation call)
  preserves an in-progress `trialing` status for the same plan so it can't
  race-clobber the trial the webhook recorded.
- The 3-days-before trial-ending reminder is delivered by the new
  `RevenueCatTrialEndingJob` (see the entry above).

### Fixed — RevenueCat product-id mapping didn't match the real App Store ids
- `RevenueCat::PlanMapping::PRODUCT_TO_PLAN` keyed on bare package names
  (`basic_monthly`, `pro_yearly`), but Apple/RevenueCat emit reverse-DNS product
  ids (`com.speakanyway.basic.monthly`, …). As a result the product-id fallback
  for plan resolution never matched, and `settings["billing_interval"]` was never
  set for IAP subscribers (analytics gap + a latent failure if a webhook ever
  arrived without entitlement ids). Added the real App Store ids (confirmed
  against the RevenueCat catalog) while keeping the bare names as a defensive
  fallback. MySpeak products are intentionally left unmapped.

### Fixed — iOS/Apple (RevenueCat) buyers could get no welcome email; Stripe webhook replays polluted the credit ledger
- **IAP welcome email is now webhook-driven.**
  `RevenueCat::WebhookProcessor#handle_purchase` now sends the plan-correct
  welcome (`User#send_plan_welcome_email_once!`) on purchase/upgrade. Previously
  the welcome only fired from the client's `POST /api/billing/update_subscription`
  call, so a dropped request (backgrounded app, crash, flaky network) after a
  completed App Store purchase left a paying user with no welcome email. The
  webhook is now the source of truth, matching the Stripe path.
- **IAP welcome is now idempotent.** `BillingController#update_subscription`
  switched from `send_welcome_email` to the idempotent
  `send_plan_welcome_email_once!`, so a retried client call (or the webhook +
  client both firing) can't double-email.
- **Stripe webhook is now idempotent end-to-end.**
  `API::WebhooksController#webhooks` records each handled event in
  `processed_webhook_events` and skips a replayed event id. Credit grants were
  already deduped on `stripe_event_id`; this extends the guard to non-credit
  handlers (downgrade on delete/pause, `past_due` on payment failure) so Stripe
  retries and dashboard replays no longer add duplicate ledger rows. The event
  is recorded only after a clean run, so genuine failures still get retried.

### Fixed — Paid-trial signups got the "Free account" welcome email
- `email_signup` (paid-intent path) was hardcoded to send `welcome_free_email`
  ("You're on the Free plan") before the user reached Stripe checkout, so
  Basic/Pro trialists got the wrong email. It now sends a plan-neutral
  `welcome_email_receipt` ("Your account is ready") tracked under
  `settings["receipt_email_sent"]`.
- The plan-correct `welcome_basic_email` / `welcome_pro_email` now ship from
  `API::WebhooksController#handle_subscription_upsert` on the first transition
  into `trialing` or `active`, via the new
  `User#send_plan_welcome_email_once!` (idempotent per `plan_type` via
  `settings["plan_welcome_sent_for"]`). This is the first path that delivers a
  Basic/Pro welcome to web subscribers; mobile IAP is unchanged.
- The Mailchimp `welcome` journey enqueue at signup is unchanged here — a
  plan-aware journey is tracked as a follow-up.

### Added — Email-only signup API + billing portal for free accounts (frictionless paid signup)
- `POST /api/v1/users/email_signup`: paid-intent visitors create an account with
  just an email (passwordless via invitation), get signed in immediately, and
  proceed to Stripe Checkout. Duplicate emails return 422 `email_taken`.
- `POST /api/v1/users/set_password` (authenticated): sets the initial password on
  a passwordless account, routed through `accept_invitation!` so the password
  actually works (devise_invitable ignores `valid_password?` while an invitation
  is pending). The legacy `POST /api/set-password` endpoint got the same fix.
- `user.api_view` now exposes `needs_password` (pending-invite accounts), driving
  the frontend's post-checkout "set a password" prompt.
- `POST /api/subscriptions/billing_portal` now works for accounts with no Stripe
  customer (lazily creates one) and returns 400 with a generic message on Stripe
  errors instead of 500. Optional `STRIPE_PORTAL_CONFIG_ID` env pins a dedicated
  portal configuration.

### Fixed — Welcome email magic link never rendered
- `UserMailer.welcome_free_email` / `welcome_basic_email` / `welcome_pro_email`
  always fell back to the `/users/sign-in` link: the raw invitation token is a
  virtual attribute that doesn't survive `deliver_later`'s GlobalID round-trip.
  The token now travels as an explicit argument, so invited users get the
  `/welcome/token/<token>` one-click sign-in link.
- The `customer.created` Stripe webhook now matches existing users by email
  before inviting, so it can no longer rotate a just-issued invitation token
  (which invalidated the magic link emailed seconds earlier).

### Changed — Demo/internal accounts receive Mailchimp journey emails again (temporary)
- Reverted #297 for now: the `user.demo_user?` guards in `MailchimpEventJob`,
  `MailchimpTrialWrapJob`, and the cohort-sweep jobs are removed, so demo
  accounts (`bhannajohns+` / `@speakanyway.com` emails) can receive lifecycle
  journey emails — useful for end-to-end testing of the journeys. Re-apply by
  reverting this revert when testing is done.

### Changed — AI image generation no longer charges credits for first-time fills
- `POST /api/images/generate` only spends `image_generation` credits when the image
  **already has a picture** (the user is replacing/customizing it). Generating an image
  for a tile/label that has **no picture yet** now generates the image for **free** — we
  don't charge users to build the shared image library. The credit gate moved from an
  unconditional check at the top of the action to `Image#display_image_url(user).present?`.
  Regenerate / image-edit / image-variation are unchanged (they always act on an existing
  image, so they keep charging).
### Added — Server-side `checkout_completed` PostHog event (upgrade funnel)
- The Stripe `checkout.session.completed` webhook now captures a
  `checkout_completed` PostHog event `{ plan, kind, amount_total, currency,
  source: "stripe_webhook" }` for both subscription checkouts and credit
  topups (`kind: "topup"`), making checkout outcomes visible in the upgrade
  funnel even when the user never returns to the success page. No new ENV
  vars — activates in production via the existing PostHog gate.

### Fixed — Dead `POST /api/v1/users/sign_in` route
- The route pointed at a non-existent `auths#sign_in` action, so any caller
  got a server error. It now routes to `auths#create`, identical to
  `POST /api/v1/login`.

### Changed — Transactional free welcome slimmed to a receipt (dual-welcome, #293 option A)
- `UserMailer.welcome_free_email` is now a short **receipt** — account-ready
  confirmation + sign-in link, with a closing line that hands off to the
  Mailchimp `welcome` Customer Journey ("we'll follow up with where to start").
  Removed the marketing sections (what-you-can-do, quick-start, MySpeak ID,
  upgrade box) that duplicated the journey's content. Subject, the "Free plan"
  badge, and the sign-in CTA are unchanged. EN + ES both updated. This lets the
  transactional receipt and the warm Mailchimp welcome coexist without
  overlapping (issue #293, option A).

### Added — Mailchimp trial-wrap (#5) and win-back (#6) lifecycle journeys
- **Trial wrapping up (#5).** The `customer.subscription.trial_will_end` Stripe
  webhook now enqueues `MailchimpTrialWrapJob`, which **personalizes** the email
  before triggering: it pushes the contact's `TRIAL_END` (formatted date),
  `BOARDS` (board count), and `COMMS` (communicator count) merge fields via the
  new `MailchimpService#update_merge_fields`, then fires the `trial_wrap`
  Customer Journey — so the copy can say "you made N boards and M communicators;
  keep them by continuing." Fires ~3 days before a Stripe no-card reverse trial
  ends (soft `basic_trial` was retired, so all trials are Stripe trials).
- **Win-back (#6).** New `MailchimpWinBackJob` (Sidekiq-cron, daily at 4:30am
  UTC) re-engages recently-dormant active users: non-admin, **≥1 board**, last
  sign-in 14–30 days ago (`WIN_BACK_DORMANT_MIN_DAYS` / `_MAX_DAYS`, tunable).
  Per-user dedupe via `user.settings["win_back_nudge_sent"]`. Requiring ≥1 board
  keeps it cleanly distinct from the legacy never-made-a-board journey (#7).
- Inert until configured: both no-op until `MAILCHIMP_JOURNEY_TRIAL_WRAP_ID` /
  `_STEP` and `MAILCHIMP_JOURNEY_WIN_BACK_ID` / `_STEP` are set, and journeys
  stay prod-only by default. #5 also needs the 3 merge fields created in the
  Mailchimp audience. (Issue #291.)

### Added — Mailchimp legacy stalled-signup re-engagement journey (#7)
- **Monthly re-engagement.** New `MailchimpLegacySignupNudgeJob` (Sidekiq-cron,
  5am UTC on the 1st of each month) finds non-admin users who created an account
  a while ago (`LEGACY_SIGNUP_NUDGE_AGE_DAYS`, default 30), never made a board,
  and haven't signed in recently (`LEGACY_SIGNUP_NUDGE_INACTIVE_DAYS`, default
  30), then enqueues the Mailchimp `legacy_signup_nudge` Customer Journey.
  Per-user dedupe via `user.settings["legacy_signup_nudge_sent"]` so each user
  is nudged once, ever.
- **Second touch, not a duplicate.** Distinct from the 48h `first_board_nudge`
  (#2) — different copy and a separate flag, so a long-dormant user who got the
  48h nudge weeks earlier may receive this once. Catches both the current
  backlog of cold signups and future stalls as they age past the threshold.
- Inert until configured: no-ops until `MAILCHIMP_JOURNEY_LEGACY_SIGNUP_NUDGE_ID`
  / `_STEP` ENV vars are set; journeys stay prod-only by default
  (`MAILCHIMP_JOURNEYS_ENABLED=true` to override in staging/dev). (Issue #294.)

### Added — Mailchimp Customer Journey triggers for first-board nudge (#2) and hit-your-limit (#3) emails
- **First-board nudge.** New `MailchimpFirstBoardNudgeJob` (Sidekiq-cron,
  daily at 4am UTC) finds non-admin users who signed up 48-72h ago with no
  boards and enqueues the Mailchimp `first_board_nudge` Customer Journey.
  Per-user dedupe via `user.settings["first_board_nudge_sent"]` so the
  same user isn't nudged across runs; the 24h window gives a missed cron
  run a chance to catch up. (Issue #291, journey #2.)
- **Hit-your-limit.** `API::BoardsController#check_board_create_permissions`
  now enqueues the Mailchimp `hit_limit` Customer Journey when a Free user
  trips the board cap on `create` / `clone` / `create_from_template`. Free
  users only; deduped per user for 14 days via `Rails.cache` so a user
  mashing the create button isn't spammed. Guarded so a Mailchimp/Redis
  blip can't 500 the API request. (Issue #291, journey #3.)
- Inert until configured: both keys no-op until
  `MAILCHIMP_JOURNEY_FIRST_BOARD_NUDGE_ID/_STEP` and
  `MAILCHIMP_JOURNEY_HIT_LIMIT_ID/_STEP` ENV vars are set, and journeys
  remain prod-only by default (`MAILCHIMP_JOURNEYS_ENABLED=true` to
  override in staging/dev).

### Added — RevenueCat / Apple IAP subscription path reaches Stripe parity
- **Closed a self-upgrade hole.** `POST /api/billing/update_subscription` no
  longer trusts the native client's claimed plan. It now verifies the user's
  entitlement against RevenueCat's REST API (`RevenueCat::Client`) and returns
  **403 `Subscription could not be verified`** unless the claimed tier matches
  an active entitlement. Requires `REVENUECAT_REST_API_KEY`.
- **Real RevenueCat webhook.** `POST /api/billing/webhooks` (previously a no-op
  stub) now verifies a shared-secret `Authorization` header
  (`REVENUECAT_WEBHOOK_AUTH_HEADER`, 401 on mismatch) and handles the full
  lifecycle, mirroring the Stripe webhook: `INITIAL_PURCHASE`/`RENEWAL`/
  `PRODUCT_CHANGE` grant the tier's credits, `EXPIRATION`/`SUBSCRIPTION_PAUSED`
  downgrade to free, `CANCELLATION` is analytics-only (access kept until
  expiry), `BILLING_ISSUE` keeps access during the grace period, plus
  `UNCANCELLATION` and `TRANSFER`. Fires the same `subscription_started` /
  `subscription_canceled` analytics + PostHog events as Stripe.
- **Idempotent & sandbox-safe.** Events are de-duped via a new
  `processed_webhook_events` table (unique on `provider`+`event_id`), so replays
  no-op; SANDBOX events are ignored in real production.
- Downgrade-to-free logic is now shared (`Billing::PlanTransitions`) so Stripe
  and RevenueCat cancellations land a user on free identically.

### Fixed — Yearly subscribers now get monthly AI credits, not one annual lump
- Plan credits are a **monthly** allowance, but a yearly subscription's grant
  previously set `plan_credits_reset_at` a full year out — so a yearly Basic/Pro
  subscriber received a single month's credits to last 12 months (this affected
  both Stripe and the new RevenueCat path). `CreditService.grant_plan!` now caps
  the grant window at `MAX_GRANT_WINDOW` (35 days), and `RefreshFreeTierCreditsJob`
  re-grants monthly for yearly Stripe subs (`settings["billing_interval"] ==
  "yearly"`) and all RevenueCat subs. Monthly subscribers are unchanged.

### Changed — Core 84 home reflowed to 14×6 with a right-side nav rail
- The Core 84 home board is now **14 columns × 6 rows** (was 12×7): on the
  one-page (no-scroll) layout, a 7th row rendered below the fold on iPad — the
  design baseline. Core word rows 1–5 are unchanged; row 6 absorbs `mine` and
  `wait`; all 10 fringe folders (People, Feelings, Food, Play, Places, Body,
  School, Time, Describe, More) now live in a 2-column rail on the right edge
  instead of being scattered through rows 6–7. Re-running
  `bin/rails vocab_sets:seed` applies the new layout to the seeded set.
  Seed-content rule going forward: **max 6 rows** on one-page boards.

### Added — Per-board thumbnails in the "Active · N" linked-boards list
- `api_view_with_predictive_images` now exposes `display_image_url` and
  `preview_image_url` on each `parent_boards` entry, so the frontend's branded
  LinkedBoardsModal (itty-bitty-frontend#320) can show a real thumbnail per
  linked board instead of only the colored initial chip. `display_image_url`
  resolves the board's stored cover with a live-preview fallback (mirrors how a
  board's own thumbnail is computed). The `parent_boards` query preloads the
  preview-image attachment to avoid an N+1 across linked boards.

### Fixed — Board Builder seeded sets: tile colors + one-page display (#279)
- **Tile colors now follow the authored Fitzgerald key.** `Board.from_obf`
  gained an opt-in `import_options[:apply_button_attributes]` (used by the
  `vocab_sets:seed` seeder only): each OBF button's authored `part_of_speech`
  is applied to the BoardImage and its background color derived via
  `ColorHelper::PRESET_DATA` (e.g. pronouns yellow `#FFEA75`, verbs green
  `#A1F571`, questions purple `#A07AFF`). OBF-standard explicit
  `background_color`/`border_color` win when authored. The shared Image's
  `part_of_speech` is backfilled only when blank — never overwritten. Re-seed
  heals mangled colors; user OBZ imports are unchanged.
- **Clones keep the authored colors.** `BoardImage#set_defaults` now respects a
  part_of_speech already present on the record (e.g. set by
  `Board#clone_with_images`' dup) instead of always re-reading the shared Image.
- **Seeded boards display on one page.** The seeder stamps
  `settings["disable_scroll"] = true` on every set board; the native board page
  reads this and fits the whole authored grid (Core 60: 10×6, Core 84: 12×7)
  on screen without scrolling. Cloned user sets inherit it.
- Run `bin/rails vocab_sets:seed` once after deploy to apply colors and
  one-page settings to existing seeded sets (already-cloned user sets keep
  their old colors).
### Added — Bulk display-label case transform
- `PUT /api/board_images/update` now accepts `payload[:label_case]`
  (`"upper"`, `"lower"`, or `"sentence"`). When present, each selected board
  image's `display_label` is rewritten in that case (sentence = first letter
  up, rest down). Falls back to the image's `label` when `display_label` is
  blank. Powers the "Aa" case buttons in the frontend bulk-edit drawer.
### Changed — Board Sets (BoardGroup) CRUD opened to all users
- Creating, editing, and organizing **Board Sets** is no longer admin-only.
  Any signed-in user can now create their own sets and manage the boards in
  them. Viewing stays public-by-link (`show` / `show_by_slug` / `preset`).
- **Security fix:** `rearrange_boards`, `save_layout`, and `remove_board` had
  **no authorization** — any signed-in user could modify (or empty out)
  anyone's set, including admin-curated predefined ones. All mutating actions
  (`update`, `destroy`, `rearrange_boards`, `save_layout`, `remove_board`, and
  the new `add_board`) now require the caller to be the set's owner or an admin,
  returning **HTTP 403** otherwise. Predefined sets remain admin-only.
- Regular users can no longer create or flip a set to `predefined`/`featured`
  — those params are stripped for non-admins.
- **Per-plan creation limits** (mirrors the board limit): Free 1, Basic 25,
  Pro 50. At the cap, `create` returns **HTTP 422** with `{ error, limit,
  count }`. Admins are unlimited. New optional env vars (defaults are sane):
  `FREE_BOARD_GROUP_LIMIT`, `BASIC_BOARD_GROUP_LIMIT`, `PRO_BOARD_GROUP_LIMIT`.
- New route `POST /api/board_groups/:id/add_board/:board_id` adds a board the
  caller owns (or a predefined/public board) to one of their sets.

### Added — Server-side PostHog subscription lifecycle events
- The Stripe webhook now fires three **server-side** PostHog events so the
  money-path funnel (pricing page → `checkout_started` → `subscription_started`)
  is buildable, and so conversions aren't missed when a user closes the
  success tab (itty-bitty-frontend#307, backend half):
  - **`trial_started`** `{ plan }` — on `customer.subscription.created` when the
    subscription is `trialing`.
  - **`subscription_started`** `{ plan, billing_interval }` — on the
    non-active→active transition (trial→paid / first activation).
  - **`subscription_cancelled`** `{ plan, reason? }` — on
    `customer.subscription.deleted` (reason from Stripe's cancellation_details
    when present).
- Each event also updates the person's `plan` property (`$set`), and uses
  `distinct_id = user.id.to_s` to match the frontend's `posthog.identify`
  contract so events land on the same person.
- Capture is **production-only** by default (staging/dev opt in via
  `POSTHOG_CAPTURE_ENABLED=true`) and wrapped so a PostHog failure can never
  break a Stripe webhook. New env vars: `POSTHOG_API_KEY`, `POSTHOG_HOST`
  (default `https://us.i.posthog.com`), `POSTHOG_CAPTURE_ENABLED`.

### Added — Robust vocabulary sets for the Board Builder (Core 60/84)
- The Board Builder picker now offers pre-authored **core vocabulary sets** (a
  real core grid + fringe category pages) alongside the small starter templates.
  Picking one **deep-clones** the seeded set for the communicator and routes the
  child's interest words into the cloned fringe pages — same one-round-trip
  flow, same `POST /api/v1/board_builder` → **201** contract.
- **Authored as our own OBF/OBZ**, reusing existing infrastructure end to end:
  sets are seeded with `ObzImporter` (grid layout + `part_of_speech` colors +
  `load_board`→`predictive_board_id` links), then cloned per user with
  `Board#clone_with_images` — so authored layout/colors are preserved (a
  rebuild-from-labels would drop them). Uses **SpeakAnyWay content only**.
- **Seeder:** `bin/rails vocab_sets:seed` imports the editable OBF-JSON source
  under `db/seeds/board_builder_sets/<slug>/` as admin, **with no `BoardGroup`** —
  a set is identified by a marker on its **root board**
  (`settings["board_builder_robust_slug"]`, via `Boards::RobustSets`).
  Idempotent. `bin/rails 'vocab_sets:build[core-60]'` emits a distributable
  `.obz`. Format spec: `db/seeds/board_builder_sets/README.md`. Slugs:
  `core-60` and `core-84` (both now ship **authored** content — see below).
- **A cloned set counts as ONE board** (root marked `builder_root`, the rest
  `builder_child`) and respects the plan board limit (**422**) and the re-run
  guard (**409** `board_builder_set_exists` unless `confirm=true`) — the same
  gates as the starter-template path. New `GET /api/v1/board_builder/templates`
  entries carry `kind: "starter" | "robust"`.
- Build runs **synchronously** for v1 (the work is DB-bound; previews/audio/AI
  art are already backgrounded). If a finalized set lands materially larger than
  the placeholder, the clone can move to a background job + "building" state
  (see `.claude-notes/board-builder.md`).
- New: `Boards::SeededSetCloner`, `Boards::RobustSets`, `VocabSets` service +
  `lib/tasks/vocab_sets.rake`. No schema changes.
- **Real Core 60 / Core 84 content seeded.** Both sets now ship authored
  SpeakAnyWay vocabulary, replacing the Core 60 placeholder and adding Core 84:
  Core 60 is a 10×6 core home + 8 fringe category pages (People, Feelings, Food,
  Drinks, Play, Places, Body, More); Core 84 is the 12×7 superset home
  with the same fringe plus School, Time, and Describe pages. Every tile carries
  a `part_of_speech` color and fringe folders link via `load_board`. Run
  `bin/rails vocab_sets:seed` to seed both as predefined, root-marked sets.

### Fixed — Board Builder vocab-set seeder now syncs removals and isolates the two sets (#277, #278)
- **Re-seed now propagates content removals (#277).** `bin/rails vocab_sets:seed`
  previously only upserted, so tiles and boards removed from the OBF source
  survived a re-seed (e.g. after the Keyboard board and the please/thank-you/and
  home tiles were cut). The seeder now runs a **destructive sync over admin-owned
  set boards only**: it destroys tiles whose label is gone from the source OBF and
  destroys boards whose `obf_id` left the manifest. `Board.from_obf` semantics for
  user OBZ imports are unchanged; **user clones (deep copies) are never touched.**
- **Core 60 and Core 84 no longer share fringe boards (#278).** Both sets used the
  same bare OBF ids (`people`, `food`, …) and seed as the same admin, so both roots
  linked to one shared fringe board and the last-seeded set won the in-set Home
  pointer — leaving the other set's cloned pages with **dead Home tiles**. Every
  board id in the seed source is now namespaced `"<slug>:<name>"` (e.g.
  `core-60:people`), so each set seeds its own disjoint fringe tree with in-set
  Home links.
- **Migration is self-healing.** The same prune step destroys the legacy
  un-namespaced boards (`people`, `food`, …) and the removed `keyboard` board, so a
  single `bin/rails vocab_sets:seed` after deploy cleans up the collision-era
  boards — no manual console cleanup.

### Fixed — Board Builder no longer silently duplicates a board set on re-run
- Re-running the wizard for the same communicator used to silently create a
  **second board set** with another `favorite: true` root (issue #269). The
  board-limit gate (#270) already blocked Free users on a re-run, but paid
  users (Basic/Pro) could stack duplicates.
- `POST /api/v1/board_builder` now **detects an existing builder set and warns**:
  it returns **HTTP 409** `{ error: "board_builder_set_exists", message,
  existing_root_id, existing_root_name, built_at }` instead of building. The
  client confirms and re-sends with **`confirm=true`** to intentionally build
  another set.
- Detection is durable and deletion-safe: each builder **root** board is now
  marked `settings["builder_root"] = true` (the counterpart to the sub-board
  `builder_child` marker), and `ChildAccount#board_builder_root` looks for one
  still attached to the communicator. Delete the set and a re-run is treated as
  a fresh build. The root stays countable — `builder_root` does not affect the
  board-limit count.

### Fixed — Board limit now enforced on all creation paths
- Three board-creation paths previously bypassed the plan board limit entirely:
  the **Board Builder** (`POST /api/v1/board_builder`), **OBF/OBZ import**
  (`POST /api/boards/import_obf`), and **create from template**
  (`POST /api/boards/create_from_template`). A Free user (limit 1) could blow
  past the cap through any of them — worst with the Board Builder, where one
  wizard run persists a whole linked tree (~5+ boards). All three now return
  **HTTP 422** when the user is already at their limit.
- A **Board Builder tree counts as ONE board** against the limit: its folder
  sub-boards are marked `settings["builder_child"]` and excluded from the count,
  so the wizard's own output never trips the read-only lock.
- Board-limit counting is centralized on `User#countable_board_count` /
  `User#at_board_limit?` (excludes predefined + builder-child boards). All gates
  — create, clone, menus, generated-board claim, and the three above — and the
  `can_create_boards` api_view flag now share this one definition, fixing prior
  count drift (`boards.count` vs filtered count).

### Changed — No-card reverse trial for Basic/Pro (issue #264)
- Starting a Basic/Pro trial **no longer requires a credit card** by default.
  Checkout uses `payment_method_collection: "if_required"` (no-card reverse
  trial): 14 days of full access, and when the trial ends without an upgrade
  the account drops to **Free in fallback mode** (#255) — never an unexpected
  charge, never stuck `past_due`.
- The trial subscription is created with
  `trial_settings.end_behavior.missing_payment_method = "cancel"`, so a
  no-card trial lapses by cleanly canceling → `customer.subscription.deleted`
  → existing Free downgrade. As a safety net, the webhook also downgrades to
  Free when a subscription update arrives as `unpaid` / `incomplete_expired`.
  `past_due` is left in Stripe dunning (real payers' failed renewals).
- The card-required arm is kept for the A/B experiment: force it per-request
  with `require_card=true` (PostHog-driven) or globally via
  `STRIPE_PAYMENT_METHOD_COLLECTION=always`. The `NOCC` /
  `bypass_payment_required` no-card path still wins over both.
- New analytics events so trial→paid is measurable: `trial_started` (on
  checkout), `trial_will_end` (Stripe pre-end webhook), and
  `subscription_started` (on the trial→paid conversion).

### Added — Board Builder wizard endpoint
- New `POST /api/v1/board_builder` builds a complete, linked board set for a
  communicator from a starter **template** plus a few **interest words**, in
  one round-trip, and `GET /api/v1/board_builder/templates` serves the picker
  catalog. Standalone feature (separate from MySpeak onboarding); the React
  page ships in the frontend.
- **Interest routing:** each interest is placed into a matching category folder
  the chosen template has (`apple` → Food, `dinosaurs` → Play); anything with
  no match lands in a single **"My Favorites"** folder, deduped, so nothing the
  user typed is dropped. Interests are normalized, capped at 12, and saved to
  the communicator so the wizard can be re-run.
- Built on the deterministic `Boards::BoardTreeBuilder` (the linked-set
  persistence half). No schema changes. See `.claude-notes/board-builder.md`.

### Added — Mailchimp Customer Journey triggers
- The backend can now enrol a contact into a **Mailchimp Customer Journey**
  via its API-trigger step, so events in the app send real, on-brand emails
  designed in the Mailchimp UI (`MailchimpService#trigger_journey`). This
  reuses the existing `MailchimpMarketing` gem — no new dependency.
- New `MailchimpEventJob` event type `"journey"` (takes `journey_key`).
  The first wired journey is **`welcome`**, enqueued on signup alongside the
  existing welcome email.
- Journey IDs are resolved per-environment from ENV
  (`MAILCHIMP_JOURNEY_<KEY>_ID` / `_STEP`) via `MailchimpClient.journey`, so
  nothing is hardcoded. Triggers fire in production only; staging/dev stay off
  unless `MAILCHIMP_JOURNEYS_ENABLED=true`, so real users are never emailed
  from non-prod.
### Added — Communicator fallback mode on downgrade (#255)
- A paid account dropping to Free now **retains** its over-limit communicators
  instead of stranding them: boards, MySpeak/profile, and the public page all
  stay intact. The communicators beyond the Free slot limit enter "fallback
  mode" — private passcode sign-in is blocked, but the public MySpeak page
  stays open and read-only, so a nonspeaking child is never cut off mid-use.
- Sign-in attempts on a fallback communicator return HTTP 403
  `communicator_in_fallback` with a `redirect_url` to the public page (the
  frontend redirect lands in itty-bitty-frontend#275). `fallback_mode` is
  exposed on the communicator API so the client can tell "in fallback" from
  "doesn't exist."
- Re-upgrading to Basic/Pro **automatically restores** sign-in, most-recently-
  active communicators first; any still over the new plan's limit stay in
  fallback. No manual re-claim. New Free signups remain capped at 1 communicator
  and are never flagged — fallback only ever results from a downgrade.

### Changed — Reprice AI feature credit costs
- Adjusted per-feature credit costs in `CreditService::FEATURE_COSTS`:
  `image_edit` 3 → 5, `image_generation` 5 → 3, `screenshot_import` 5 → 3,
  `scenario_create` 10 → 5, and `menu_create` 10 → 5. (`word_suggestion`,
  `board_format`, and `image_variation` are unchanged.)
- Aligned the credit specs (`credit_service_spec`, `credit_enforcement_spec`,
  `board_images_rate_limit_spec`) with the new costs — the repricing landed
  without updating them, which had turned `main` red.

### Changed — Drop the no-CC `basic_trial` soft trial (Option A)
- Every new signup now starts on **Free** (5 credits, Free-tier limits)
  instead of the 14-day no-credit-card `basic_trial`. The credit-card
  Stripe trial is unchanged. This closes the loophole where a signup could
  stack ~28 days of premium-level access (no-CC trial + CC Stripe trial)
  before the first charge.
- Removed the `before_create :set_soft_trial_plan` callback (replaced with
  `setup_new_user_free_plan`, which applies Free limits on create) and the
  login-time re-apply in `API::V1::AuthsController#create`.
- Existing `basic_trial` users are migrated to Free via the one-off
  `bin/rails plans:migrate_basic_trial_to_free` task (run on production
  after deploy). The remaining `basic_trial` plumbing
  (`CreditService`, `setup_limits`, `RefreshFreeTierCreditsJob`,
  `DowngradeSoftTrialJob`) is kept as a harmless fallback.

### Changed — Board create accepts topic + word_list together (#246)
- `POST /api/boards` now accepts a situation (`topic`/`prompt`) and seed
  words (`word_list`) in the same request. The redesigned `/boards/new`
  merges "Create from Scratch" and "Create from Scenario" into one
  "Build a board" form; the `default` and `scenario` creation types now
  share a single code path in `API::BoardsController#create`.
- `word_count` is clamped server-side to `1..50` (accepts either
  `wordCount` or `word_count`), so an oversized client value can't drive
  a huge AI prompt.
- `age_range` (`ageRange`/`age_range`) is optional on both paths —
  `GenerateBoardJob` falls back to its own default when blank.
- `GenerateBoardJob`'s `default`/`scenario` strategy now combines the
  seed `word_list` with topic-generated words (deduped). A board with
  seed words but no topic just keeps the seed words.
- Affected files: `app/controllers/api/boards_controller.rb`,
  `app/sidekiq/generate_board_job.rb`.

### Changed — Background-queue all user-lifecycle emails (#207, phase 2)
- Every inline `deliver_now` in request and lifecycle paths is now
  `deliver_later`. Welcome, plan-change, team invitation, claim-link,
  setup, confirm-email-update, message notification, and admin
  feedback emails all enqueue to Sidekiq instead of blocking the
  request thread on SMTP.
- Affected files: `app/models/user.rb` (17 sites),
  `app/controllers/api/users_controller.rb` (2 sites),
  `app/models/message.rb`, `app/models/feedback_item.rb`,
  `app/models/child_account.rb`. `DiskSpaceAlertJob` still uses
  `deliver_now` — it already runs inside Sidekiq.
- Closes the last hot-path SMTP risk identified in the 2026-05-30
  outage (#207). Pairs with PR #208 (SMTP timeouts, OpenAI timeouts,
  puma cluster mode).
- User-visible: faster HTTP responses on signup, plan change, team
  invites, email-change confirmation. Email arrival time unchanged
  (Gmail-side delivery dominates).
- Added `spec/lib/no_inline_mailer_delivery_spec.rb` as a regression
  guard so a new `deliver_now` outside `app/sidekiq/` fails CI.

### Changed — OBF/OBZ import: opt-in for image binaries, private-by-default (#239)
- `POST /api/boards/import_obf` no longer downloads or stores image
  binaries from imported `.obz` / `.obf` files by default. Board
  structure imports as before; tiles render with their label and the
  user's existing matching images, but bundled symbol PNGs are not
  pulled into S3 unless the client opts in.
- Two new params:
  - `include_images` (bool, default `false`) — when `true`, the importer
    calls `Down.download` per OBF image entry and creates Docs.
  - `image_license_acknowledged` (bool, default `false`) — required to
    be `true` when `include_images=true`. Otherwise the request returns
    **HTTP 400 `image_license_required`**.
- Every `Image` row created via OBF/OBZ import is now `is_private: true`,
  unconditionally. They never enter the `public_img` scope or other
  users' search results. An admin can flip individual images public later.
- `BoardGroup.settings["imported_from_obf"]` now records the audit trail
  per import: `include_images`, `license_acknowledged`,
  `acknowledged_by_user_id`, `acknowledged_at`, `imported_by_user_id`,
  and the OBF root board's `license` block (if any).
- **Why:** previously, importing a CoughDrop / TouchChat `.obz` with
  proprietary symbol assets (e.g. SymbolStix) would land those PNGs in
  S3 with `is_private=false`, exposing licensed artwork to every user
  via `Image.searchable_images_for`.
- **Frontend impact:** existing upload modal continues to succeed
  without changes, but imports will be structure-only until the
  frontend adds an "Import images" + "I have permission" pair of
  checkboxes that send the new params.
- **Fixed alongside:** `GET /api/boards` (user's own listing) used to
  silently drop OBF-imported boards via `where(obf_id: nil)`, so
  `board_count` and the visible list disagreed (e.g. 6 vs 4).
  The filter belongs on cross-user discovery scopes
  (`Board.searchable`, `Board.public_boards`), not on a user's own
  index. Removed there; kept on the discovery scopes.
### Changed — Owners can archive active communicators (issue #237)
- `ChildAccount#archive!` now allows archiving owner-controlled active
  communicators in addition to sandboxes. Loaner is still excluded —
  callers get an `ArgumentError` pointing at `end_loan` / `reclaim!`.
- Archive stamps `settings["archive_reason"]` and
  `settings["archived_status"]` so support has an audit trail and
  `unarchive!` can restore the original status cleanly.
- `ChildAccount#unarchive!` re-checks the owner's slot limit when
  restoring a previously-active record (archive frees the slot via the
  default scope; the owner may have filled it). Raises
  `ChildAccount::SlotFull` when at-cap.
- `POST /api/child_accounts/:id/archive` now returns 200 for an active
  owner, 422 (`End the loan first via end_loan.`) for a loaner, and
  401 for non-owners. `POST /:id/unarchive` returns 422 with the slot
  message when the owner is at-cap.
- Frontend `LoanerControls.tsx` work is tracked separately in
  `rally25rs/itty-bitty-frontend`.

### Changed — Pro plan now includes 5 Communicators (was 3)
- `User::PRO_PLAN_LIMITS["paid_communicator_limit"]` default bumped
  from `3` → `5` in `app/models/user.rb`. Same `PRO_PAID_COMMUNICATOR_LIMIT`
  env var; if it's set in prod it now needs to be `5` (or unset to take
  the new default).
- Updated the slot-math comment block in
  `app/helpers/permissions/communicator_limits.rb` and the test in
  `spec/models/user_plan_limits_spec.rb`.
- `welcome_pro_email.html.erb` fallback and `pro_setup_email`
  locale string both updated to "5 Communicator Accounts".
- **Backfill:** new `rake plans:bump_pro_to_five_communicators` task in
  `lib/tasks/plans.rake`. Bumps any current Pro / `pro_yearly` /
  `partner_pro` user whose `paid_communicator_limit` is 3 (or missing)
  up to 5. Skips anyone already above 3 so admin-tuned values aren't
  clobbered. Run with `DRY_RUN=true` first.
- Decision rationale in `marketing/pricing-structure.md` (REVISED
  2026-05-31 entry).

### Fixed — Subscription lifecycle bugs (#199)
- `paid_plan?` now considers `plan_status`: a user with
  `plan_type=basic` + `plan_status=canceled` (e.g. a missed
  `subscription.deleted` webhook) no longer passes paid gates.
  Returns `false` for nil plan_type instead of raising.
- `set_soft_trial_plan` moved from `before_save` to `before_create` and
  guards on `paid_plan_type`. Users who deliberately downgraded to free
  or picked a paid tier at signup are no longer bounced back to
  `basic_trial` on subsequent saves within the 14-day window.
- `invoice.payment_failed` Stripe webhook is now handled — flips
  `plan_status` to `past_due`. Does not downgrade; Stripe dunning still
  drives the eventual `subscription.deleted`.
- `handle_subscription_upsert` no longer silently downgrades paid users
  to `free` when a Stripe Price is missing `plan_type` metadata; it
  preserves the user's existing plan_type and logs a warning.
- `handle_invoice_payment_succeeded` reads the new Stripe
  `invoice.parent.subscription_details.subscription` path in addition
  to the deprecated `invoice.subscription` field.
- `API::BillingController#update_subscription` no longer calls a
  nonexistent `setup_limits_for_plan` method.
### Changed — Harden production puma against silent outbound-call wedges (#207)
- **Puma cluster mode in production.** `config/puma.rb` now sets `workers 2`
  (overridable via `WEB_CONCURRENCY`), `worker_timeout 30`, and
  `preload_app!` for production. A worker that wedges no longer takes the
  whole site down — the other worker keeps serving at 50% capacity.
- **SMTP timeouts.** `config/environments/production.rb` `smtp_settings`
  now sets `open_timeout: 10` and `read_timeout: 20`. Previously a stalled
  Gmail SMTP session could hang a puma thread for the Net::SMTP default
  (much longer); on 2026-05-30 this contributed to a 38-minute outage where
  all 8 single-mode threads silently wedged after a deploy.
- **OpenAI request_timeout.** `OpenAiClient::OPENAI_REQUEST_TIMEOUT_SECONDS`
  (defaults to 60s, overridable via `OPENAI_REQUEST_TIMEOUT`) is now passed
  to every `OpenAI::Client.new` — the central wrapper and the nine direct
  call sites in `app/services/*` and `app/controllers/api/scenarios_controller.rb`.
- No user-facing behavior change; reliability/SLO improvement only.
- Net effect: a future hang in SMTP or OpenAI raises an exception after the
  cap instead of holding a thread; with cluster mode, even a deadlock that
  the timeouts don't catch only halves capacity instead of taking the site
  fully offline.

### Changed — MySpeak starter-board seed populates tiles + tags `myspeak` (#204)
- `db/seeds/myspeak_starter_boards.rb` now creates **5** starter boards
  (`myspeak-basics`, `myspeak-feelings`, `myspeak-social`,
  `myspeak-food`, `myspeak-school`), tags each with `myspeak` so they
  appear in `Board.myspeak_public_boards`, and seeds **6 starter tiles**
  per board via `Board#find_or_create_images_from_word_list`.
- Net effect: the MySpeak onboarding picker
  (`GET /api/public_boards?myspeak=true`) renders 5 cards with real
  tile previews instead of one empty card.
- Idempotent: per-board tile add is gated by an existing-label check,
  so re-running the seed will not duplicate `board_images`.
- Run after deploy: `bin/rails runner db/seeds/myspeak_starter_boards.rb`.
  Adding new tiles enqueues `GenerateImagesJob` for any image without an
  existing display doc — let Sidekiq drain before verifying the picker.

### Added — `has_boards` flag on `User#api_view`
- `User#api_view` now returns `has_boards: boolean` alongside
  `board_count`. Derived from the already-computed `board_count`
  (zero extra queries) so the new free-tier dashboard
  (`itty-bitty-frontend` PR #183) can branch on an explicit boolean
  instead of `(board_count ?? 0) > 0`. No behavior change for
  existing clients — additive field only.

### Added — Free = 1 MySpeak ID limit (#143)
- Free users are now capped at **one MySpeak ID** (Profile). Basic/Pro
  and admins remain unlimited. Trial users (`basic_trial`, Stripe
  `trialing`) are treated as paid by `User#paid_plan?` and the gate
  doesn't trigger.
- "MySpeak ID" counts a Profile attached to the user directly *or* to
  one of their `communicator_accounts`.
- `POST /api/profiles` returns **HTTP 403** with
  `{ error: "myspeak_id_limit_reached", message, limit, count }` when a
  Free user is already at the cap.
- Limit env-tunable via `FREE_MYSPEAK_ID_LIMIT` (default `1`).
- New helpers on `User`: `#myspeak_id_limit`, `#myspeak_id_count`,
  `#can_create_myspeak_id?`.

### Changed — CommunicationAccountMailer per-recipient i18n (#175)
- `CommunicationAccountMailer` now extends `BaseMailer` (was
  `ApplicationMailer`).
- `setup_email` and `claim_link_email` wrap `mail(...)` in
  `with_user_locale(@account.owner)` and resolve subjects + bodies through
  `I18n.t`. Locale keys under `communication_account_mailer:` in
  `config/locales/mailer.{en,es}.yml`.
- Recipient is the `ChildAccount.email` (or the parent email for the
  claim flow), not a `User` — so the **owner's** locale is used, with a
  safe fallback to `:en` when the account has no owner.
- Bundled `claim_link_email` along with the explicitly-scoped
  `setup_email` since they share the class — leaving one English would
  defeat the goal of making the class locale-aware.

### Changed — BaseMailer team_invitation_email per-recipient i18n (#174)
- `BaseMailer#team_invitation_email` now wraps `mail(...)` in
  `with_user_locale(@invitee)` and resolves subject + body through
  `I18n.t`. Locale keys under `base_mailer:` in
  `config/locales/mailer.{en,es}.yml`. Invitees whose `i18n_locale` is
  `:es` now receive team invitations in Spanish.
- Deleted the orphan template
  `app/views/base_mailer/invite_new_user_to_team_email.html.erb` —
  no mailer action referenced it anywhere in the codebase.

### Changed — PartnerMailer per-recipient i18n (#173)
- `PartnerMailer` now extends `BaseMailer` (was `ApplicationMailer`).
- `PartnerMailer#welcome_email` wraps `mail(...)` in
  `with_user_locale(@user)` and resolves subject + body through `I18n.t`.
- English and Spanish keys under `partner_mailer:` in
  `config/locales/mailer.{en,es}.yml`.
- Known limitation: `@start_date` / `@end_date` are still formatted in
  English (`strftime("%B %d, %Y")`) and interpolated into the dates
  string. Proper date localization would need `I18n.l` and `:date.formats`
  locale data, which isn't currently set up project-wide. Tracked as
  a follow-up.

### Changed — SetupMailer per-recipient i18n (#172)
- `SetupMailer#myspeak_setup_email`, `vendor_setup_email`, `pro_setup_email`,
  and `basic_setup_email` now wrap `mail(...)` in `with_user_locale(@user)`
  and resolve subject + body through `I18n.t`. English and Spanish keys live
  under `setup_mailer:` in `config/locales/mailer.{en,es}.yml`. Free users
  whose `i18n_locale` is `:es` now receive setup emails in Spanish.
- Vendor setup template now reads `@user.name` instead of the undefined
  `@vendor.name`. The previous reference would have raised `NoMethodError`
  whenever the vendor email actually rendered (the mailer action only ever
  assigned `@user`); the error was masked by the same `rescue` that masked
  #176.

### Fixed — SetupMailer free/SLP setup email actions (#176)
- `User#send_free_setup_email` was calling a non-existent
  `SetupMailer#free_setup_email` action with an empty template, swallowing
  a `NoMethodError` in a `rescue` and never delivering the email. It now
  delivers `UserMailer#welcome_free_email` (already i18n'd, free-tier
  appropriate). The admin "send setup email" action on
  `/api/admin/users/:id/send_setup_email` now works for Free users.
- Deleted the empty `setup_mailer/free_setup_email.html.erb` and
  `setup_mailer/slp_setup_email.html.erb` templates. The SLP template had
  no callers anywhere in the codebase.

### Changed — AI word suggestions respect `board.language`
- `GET /api/boards/words` and `GET /api/boards/:id/additional_words` now
  source the language for AI output as `params[:language] || board.language ||
  current_user.i18n_locale`. A board with `language: "es"` returns Spanish
  suggestions even when the requesting user's UI is in English. The new
  `params[:language]` query param lets the caller override the board's
  language for one-off requests.
- `POST /api/scenarios/suggestion` (the scenario description generator)
  now honors `params[:language]`, falling back to the requesting user's
  locale. Closes the last gap in #118 — the scenario suggestion path
  previously built its own English-only prompt that ignored language.
- Threading also reaches the social-story path (`OpenAiClient` and
  `Board#get_social_story_word_suggestions`), which previously had no
  language-aware prompt.

### Added — Multilingual backend content (i18n Phase 1)
- **AI generation now respects the user's language.** Word suggestions, board
  generation, and scenario word lists previously always came back in English.
  The AI word-suggestion paths (`GET /api/boards/words`,
  `POST /api/boards/:id/additional_words`, `GET /api/scenarios/get_words`, and
  the async board/scenario generators) now thread the requesting user's
  language through to OpenAI, which is instructed to "Respond in <language>".
  English users see byte-identical output.
- **New boards default to the creator's language.** `POST /api/boards` now sets
  `board.language` from the creator's language setting when no explicit
  `language` param is sent (an explicit param still wins).
- **Per-language TTS audio.** The audio pipeline previously wrote
  `_<lang>`-suffixed files but synthesized the *English* label with
  *English-only* Polly voices. It now synthesizes the translated label and
  picks language-appropriate voices (`VoiceService.voices_for_language`).
  `TranslateImageJob` chains a `CreateAllAudioJob` so localized audio is
  generated once a translation lands.

### Fixed — Translated tile labels were silently ignored
- `BoardImage#set_labels` looked up the `language_settings` jsonb with symbol
  keys, but the column stores string keys — so translated labels were never
  read and tiles always fell back to English. Now uses string keys.

### Added — B&W and QR options for board PDF downloads

- `GET /api/boards/:id/pdf` now accepts `bw=1` for a copier-friendly black-and-white render (no tile backgrounds, grayscale images, black borders) and `qr=0` to suppress the QR code in the header. Defaults preserve existing behavior: color render with QR included. Variants are streamed but not stored on the board's cached `pdf_file` attachment, so the default PDF stays canonical. B&W downloads are named `<slug>-board-bw.pdf` to disambiguate.

### Fixed — Team owner can't be removed or demoted by other team members

- After the SLP→parent claim hand-off, the parent (new owner) is protected on the communicator's team. An SLP supervisor — or any non-owner team member — can no longer remove the parent owner via `DELETE /api/teams/:id/remove_member`, demote the owner via the invite endpoint, or self-promote themselves to admin. Attempts return HTTP 403 with structured errors (`cannot_remove_owner`, `cannot_change_owner_role`, `cannot_self_promote`). The owner can still remove themselves; system admins retain an escape hatch.
- Team `show`/`index` `api_view` now exposes `account_owner_ids` and per-member `is_account_owner` so the frontend can hide destructive controls on the owner row.

### Changed — Downgraded users keep their boards (read-only, never deleted)
- When a paid user (Basic/Pro) cancels and lands back on Free, their existing boards are no longer all fully editable. Boards beyond the Free limit (1) become **read-only**: they still open, cells still tap, audio still plays — so a non-speaking user's communication never breaks — but content-editing (renaming, layout changes, image swaps, audio uploads) is blocked behind an upgrade prompt. Previously, a Pro user with dozens of boards who cancelled kept full edit access to every one of them forever; only *creating* a new board was blocked.
- Users pick which single board keeps full edit access via `PATCH /api/boards/:id/make_editable`. On downgrade the backend pins a sensible default (favorite or most-recent) so they're never fully locked out before they choose.
- Locked content-editing endpoints return HTTP 403 with `error: "board_locked"`. Reads, audio playback, and board deletion are never gated.
### Fixed — Menu board display image saved at full size

- A menu board's `display_image_url` was set to the 288×288 tile variant (`Doc#tile_url`) of the uploaded menu photo, so the menu looked blurry whenever it was shown at any meaningful size. It now stores the full-resolution image (`Doc#display_url`) — a menu has fine print and must stay legible on a full screen. Applies to both menu board creation and re-run.

### Added — `ai_credits` in admin user views

- `User#admin_api_view` and `User#admin_index_view` now include an `ai_credits` object (`CreditService.balance`: `plan`, `topup`, `total`, `reset_at`), so the admin user pages can display each user's AI credit balance.

### Changed — Menu boards are built from the image with AI vision

- Creating a "menu" board now sends the uploaded menu photo straight to an AI vision model (`MenuVisionService`, OpenAI Responses API) to extract the food and drink items. Previously the React app ran Tesseract.js OCR in the browser and sent the raw text; OCR on real-world menu photos (glare, angled shots, multi-column layouts) was unreliable, and the backend then stripped digits, punctuation, and line breaks before parsing — erasing the item boundaries the model needed.
- The menu form no longer runs in-browser OCR; it just uploads the image. The dead OCR text-parsing path (`OpenAiClient#clarify_image_description` / `#describe_menu` / `#strip_image_description`, `ImageHelper#clarify_image_description`, `Menu#describe_menu`) has been removed.
- New optional env var `MENU_VISION_MODEL` (default `gpt-4.1-mini`) selects the vision model.

### Fixed — Duplicate `SaveAudioJob` enqueued per board image

- `Board#add_image` enqueued `SaveAudioJob` twice for every image added to a board: once explicitly, and once via `BoardImage`'s `after_create :create_voice_audio_after_create` callback. Both jobs did the identical Polly audio lookup/creation and board-image update — wasted work and a mild race creating the same audio file concurrently. `add_image` now leaves audio generation entirely to the callback.

### Changed — MySpeak is now a free feature, the $3 MySpeak tier is retired

- The MySpeak ID (a demo communicator with a public profile, QR code, and emergency info) is now included on the **Free** plan. `FREE_DEMO_COMMUNICATOR_LIMIT` default is now `1` (was `0`), so every Free user can create one MySpeak demo communicator. That demo communicator is capped at one board (`ChildAccount::FREE_DEMO_BOARD_LIMIT`); Pro demo accounts keep the 3-board default.
- The `myspeak` / `myspeak_yearly` plan tier has been removed: dropped from `setup_limits`, Stripe checkout (`PLAN_PRICE_IDS`), `normalize_plan_key`, `BillingController` accepted plans, `CreditService::PLAN_MONTHLY_CREDITS`, `RefreshFreeTierCreditsJob`, and the Mailchimp tagging job. `User#myspeak?` is replaced by `User#has_myspeak_feature?` (true when the user has a demo-communicator slot).
- Run `bin/rails plans:migrate_myspeak_to_free` to move any existing `myspeak` / `myspeak_yearly` users onto the free plan (idempotent). Effective plan limits come from `config/application.yml` + host config, so `FREE_DEMO_COMMUNICATOR_LIMIT` must also be set there for the change to take effect outside CI.

### Fixed — Authenticated SMTP for production mail delivery

- Production mail now authenticates over SMTP when `SMTP_USERNAME`/`SMTP_PASSWORD` are set, instead of relying solely on `smtp-relay.gmail.com`'s IP-allowlist auth. The `mail:test` diagnostic showed production failing with `OpenSSL::SSL::SSLError: SSL_read: unexpected eof while reading` — the relay dropping unauthenticated connections from a non-allowlisted server IP, so every welcome email and team invite was silently failing.
- With credentials present, delivery uses authenticated `smtp.gmail.com` (IP-independent). With no credentials present, behavior is unchanged (the IP relay). `SMTP_ADDRESS` overrides the SMTP host — set it to `smtp-relay.gmail.com` to use the relay endpoint _with_ authentication.

### Fixed — Mail delivery diagnostics & production transport config

- Restored the explicit `config.action_mailer.delivery_method = :smtp` in `config/environments/production.rb` — it was dropped when the SMTP block was swapped to `smtp-relay.gmail.com`, leaving production reliant on the framework default. Documented the relay's IP-allowlist failure mode (delivery fails silently if the EC2/Hatchbox outbound IP is not registered in the Google Workspace SMTP relay console).
- Added `bin/rails 'mail:test[you@example.com]'`: prints the resolved ActionMailer config and attempts a real delivery, surfacing the actual SMTP error (credential failure, unallowlisted IP, connection refused) instead of letting it be swallowed by the `rescue` blocks in `User#send_welcome_email` and friends.

### Fixed — Demo account plan limits & legacy monthly-limit cleanup

- `MYSPEAK_DEMO_COMMUNICATOR_LIMIT` default changed from 1 to 0 and `PRO_DEMO_COMMUNICATOR_LIMIT` default from 10 to 1, so demo communicator accounts are granted to Pro only (1 account), matching the intended pricing model. `FREE` and `BASIC` were already 0.
- Removed the dead `API::ApplicationController#check_monthly_limit` helper — a legacy Redis-counter rate limit with no callers. AI features gate on `check_credits!` / `CreditService`. `MonthlyFeatureLimiter` and `User#monthly_limit_for` are intentionally kept: they still back the `can_use_ai?` / `ai_limit_reached?` path, whose cleanup is tracked separately.

### Changed — MySpeak quick-comm board now works on the Free tier

- `ChildAccount#favorite_boards` was plan-gated (`paid_plan?` / vendor), so a Free-tier user's MySpeak page showed an empty quick-comm board. Removed the gate — favorited boards now populate the MySpeak public page and `go_to_boards` for all tiers, including Free. Part of the MySpeak-goes-free rollout (itty_bitty_boards#142). MySpeak ID, profile, QR code, and safety/medical cards had no plan gate to begin with.

### Added — `core_boards:seed` rake task for public "Core + X" boards

- New `bin/rails core_boards:seed` task creates public, predefined boards modeled on the "Core + Lunch" board: an 8-column × 5-row, 40-tile grid with 20 fixed core words on the left half (black-bordered) and 20 topic words on the right half (borderless). Tiles are colored by part of speech via the modified Fitzgerald key.
- Topic words come from a curated list when the topic is known (`Lunch`, `Playground`, `Swimming`); otherwise they are AI-generated via `Board#get_words_for_scenario`. Controlled by env vars: `TOPICS="Playground,Swimming"`, `COUNT=n`, `AGE_RANGE`, and `DRY_RUN=1`.
- Reuses existing image artwork only — no image generation is queued, so the task incurs no image API cost. Words without artwork render as placeholders. Idempotent: boards that already have tiles are skipped.

### Added — Disable Audit Logging for communicator accounts

- Communicator (child) accounts now support a `settings["disable_audit_logging"]` flag, matching the existing flag on user accounts. When set, that communicator's word clicks are not recorded as `WordEvent` records. Toggled from the communicator account form.
- `API::Audits#word_click` and `#public_word_click` now skip `WordEvent.create` when the acting user or the communicator account has audit logging disabled (new `User#audit_logging_disabled?` / `ChildAccount#audit_logging_disabled?` helpers). Previously the user-level flag was honored only by the frontend; it is now enforced server-side as well.

### Added — Range-aware communicator stats endpoint

- New `GET /api/word_events/stats?account_id=X&days=N` (`API::Audits#communicator_stats`) returns a single bundled, range-filtered stats payload for a communicator account's Stats tab: `range`, `summary` (total events, unique words, active days, most active day, average per active day, top word), `heat_map`, `most_clicked_words`, `part_of_speech_breakdown`, and the word `events` list (capped at 500). `days` accepts 30/60/90/180/365 and falls back to 180 for any other value. Previously the Stats tab pulled an all-time `heat_map` and a fixed 7-day `most_clicked_words` from `child_accounts#show`, so its day-range selector had no effect on the data.
- `WordEventsHelper#heat_map` now takes an optional range argument; added `WordEventsHelper#word_events_summary(range)` and `#part_of_speech_breakdown(range)`. Existing no-arg `heat_map` callers are unchanged.

### Added — Communication Prompt Mode for caregivers

- New `CoachingPromptSet` model + `API::CoachingPrompts` controller (`GET/POST/PATCH/DELETE /api/coaching_prompts`). A caregiver opens a board in Caregiver Mode and the API returns a coaching prompt set with strategies + tappable example phrases. Curated SpeakAnyWay sets ship for Snack Time, Car Ride, Bedtime Story (matched against `Board#tags` / name tokens). For boards without a curated match, `CoachingPromptGenerator` calls OpenAI (`gpt-4o-mini`) once and caches the result on the board's `metadata` jsonb so the second visit costs nothing. Staging skips the paid call and returns the bundled fallback set, mirroring the existing OpenAI image staging stub.
- Users can create / edit / delete their own custom coaching sets via the same endpoint — owned sets are scoped by `user_id`. Editing SpeakAnyWay-shipped or another user's sets returns 403.
- New `users.settings["is_caregiver"]` flag — opt-in preference lives in the existing user settings jsonb (same pattern as `wait_to_speak`, `show_labels`, etc.). Flipped via the existing `POST /api/users/:id/update_settings` endpoint, exposed in the Settings page UI.
- Free for everyone — no `CreditService` gating. Cost is bounded by per-board caching of AI fallback generations.
- **Audio cache**: `GET /api/coaching_prompts/audio?text=...&voice=...&language=...` returns a stable mp3 URL for a coaching phrase + voice tuple. Backed by a new `CoachingPhraseAudio` model with an ActiveStorage attachment, keyed on `sha256(version|text|voice|language)`. First call synthesizes via the existing `VoiceService` (Polly / OpenAI) and uploads to S3; every subsequent caller for the same tuple — across the whole app — gets the same URL without hitting TTS. Race-safe via a unique-index `phrase_key` column. Skips synthesis in `Rails.env.test?` unless `ENV["ALLOW_COACHING_AUDIO_TTS"]` is set.

### Fixed — Pro users showing 0 AI credits ("granted and expired same day")

- `CreditService.grant_plan!` now clamps `period_end` to a minimum of
  `Time.current + 1.day` (`CreditService::MIN_GRANT_WINDOW`). A bad
  upstream value (stale `plan_expires_at`, `trial_end == 0`, etc.) was
  causing the new `plan_grant` row to land already-expired, and the
  hourly `ExpirePlanCreditsJob` would sweep it to 0 within the hour.
  Issue #110 patched the rake task; this patches the service so no
  caller can reintroduce it. A `Rails.logger.warn` fires on every clamp
  so we can find any upstream caller still writing bad dates.

### Changed — Free tier is now 5 AI credits/month (was 10)

- `PLAN_MONTHLY_CREDITS["free"]` lowered from 10 to 5. Applies to
  signup grants, the daily refresh job, and post-cancellation grants.

### Changed — Canceled/paused subscriptions keep 5 free credits (was 0)

- `customer.subscription.deleted` and `customer.subscription.paused`
  webhooks previously called `CreditService.expire_plan_credits!`,
  leaving the user at 0 until the next daily refresh. Now they call
  `CreditService.grant_plan!` with the free-tier allowance, so users
  land on free with 5 credits immediately. The prior balance is still
  expired (ledger trace preserved); top-ups are still untouched.

### Changed — Monthly credit refresh now covers non-Stripe paying users

- `RefreshFreeTierCreditsJob` (daily, 3am UTC) used to refresh only
  `free` and `basic_trial` users. It now also refreshes any user
  without a `stripe_subscription_id` — App Store / RevenueCat
  subscribers, admin/demo accounts on paid tiers — granting their
  actual plan_type's allowance (Pro = 1500, Basic = 400, etc.).
  Stripe-driven paying users continue to be refreshed by
  `invoice.payment_succeeded`. Class name unchanged for cron stability.

### Added — AI word suggestions adapt to the communicator

- Board generation now accepts an optional communicator profile — `age` / `age_band`,
  `aac_level` (`emerging` / `developing` / `proficient`), and `vocab_type` (`core` /
  `fringe` / `balanced`) — on the AI word-suggestion endpoints (`GET /api/boards/words`,
  `POST /api/boards/:id/additional_words`) and the scenario board create flow. For young
  or emerging communicators the prompt now leans on core vocabulary, verbs, and emotions
  instead of clinically literate adult nouns. All fields are optional; callers that send
  no profile get the same output as before. Normalization lives in the new
  `CommunicatorProfile` service object.

### Fixed — Private boards no longer viewable by anyone with the link

- `GET /api/boards/:id` (which backs the frontend `/pb/<slug>` route) is unauthenticated
  and previously rendered any board regardless of ownership or publish state — a
  logged-out visitor could view a private board with just its slug. It now returns a
  generic 404 unless the board is published, or the requester is the owner, an admin, or
  a member of a team the board is shared with (`Board#viewable_by?`).

### Changed — Staging no longer makes paid OpenAI image calls

- When `ENV["STAGING"] == "true"`, all OpenAI image operations (generation, variations, edits) are stubbed with the bundled `public/placeholder.jpeg` instead of hitting the paid API. The rest of the image pipeline (Doc creation, ActiveStorage attachment, board tiles, status transitions) runs normally, so staging can be exercised end-to-end without spending money. Production behavior is unchanged. Gated via the new `AppEnv.staging?` helper.

### Fixed — AI credits now actually grant on signup and refresh for free users

- **Signup grant.** New users land in `basic_trial` for 14 days (via `User#set_soft_trial_plan`) but the after-create flow never granted them any credits, so every AI call returned `402 insufficient_credits`. Added `User#grant_initial_plan_credits` (after_create) → `CreditService.ensure_initial_grant!(user)` which writes a `plan_grant` row sized to the tier (`basic_trial` = 400, matching Basic; `free` = 10; etc.) with `expires_at` of 14 days for trial users and 30 days for everyone else.
- **`basic_trial` plan_type was missing from `CreditService::PLAN_MONTHLY_CREDITS`** — it fell back to free (10 credits) instead of the intended Basic-equivalent (400). Fixed.
- **Soft-trial downgrade now grants free credits.** `DowngradeSoftTrialJob` (daily at 2am UTC) flips expired trial users to `free`; now also calls `CreditService.grant_plan!` for 10 credits with a 30-day expiry so they don't see balance=0 the moment they're downgraded.
- **Monthly refresh for non-subscription tiers.** New `RefreshFreeTierCreditsJob` runs daily at 3am UTC and re-grants the tier allowance to users on `free` / `basic_trial` whose `plan_credits_reset_at` has passed. Paid Stripe subscribers (MySpeak, Basic, Pro, Partner Pro) continue to be refreshed by `invoice.payment_succeeded`; the new job is just for users without a Stripe billing cycle.

### Added — Phase 4 of usage-based AI pricing (renewals + auto-grant)

- `invoice.payment_succeeded` webhook handler — fires on initial paid period and every renewal. Reads `monthly_credits` and `plan_type` from the subscription line's Price metadata (falls back to `CreditService::PLAN_MONTHLY_CREDITS`), then calls `CreditService.grant_plan!` with `period_end = subscription.current_period_end`. Idempotent on Stripe event id, so retried webhooks never double-credit.
- `customer.subscription.created` (status `trialing`) now grants trial credits with `period_end = subscription.trial_end`. Paid subscriptions still get their credits via the invoice path.
- `customer.subscription.deleted` / `.paused` now expire plan credits via `CreditService.expire_plan_credits!`. Top-up credits are preserved.
- `ExpirePlanCreditsJob` runs hourly as a backstop — zeroes out plan credits whose `plan_credits_reset_at` has passed and no webhook arrived to refresh them.
- **Fix:** `apply_free_plan` previously referenced `FREE_PLAN_LIMITS` unqualified in the controller, which raised `NameError` silently swallowed by the `rescue` — so cancellations never actually downgraded users. Now resolves `User::FREE_PLAN_LIMITS` correctly.

### Changed — Phase 3 of usage-based AI pricing (enforcement switched)

- **AI features now spend credits at request time.** The Redis monthly counter (`MonthlyFeatureLimiter`) is no longer in the AI hot path — `CreditService.spend!` is the source of truth.
- New API gating helper `check_credits!(feature_key:, feature_name:, amount: nil)` in `API::ApplicationController`. Admins bypass the check.
- AI endpoints now return **HTTP 402 `insufficient_credits`** with `{ feature, needed, balance, plan_credits, topup_credits, reset_at, topup_url }` when the balance is too low. HTTP 429 is reserved for true rate limiting and is no longer used by AI gating.
- All 10 AI controller callsites now charge weighted credits per their real feature (image_generation=5, image_edit=3, scenario_create=10, etc.) instead of a flat `ai_action=1`.
- Shadow-mode telemetry from Phase 1 has been removed. `check_monthly_limit` remains in the codebase as a generic Redis-counter helper but is no longer wired to AI endpoints.

### Added — Phase 2 of usage-based AI pricing

- `POST /api/stripe/checkout_sessions/topup` — creates a one-time Stripe Checkout Session for a credit pack (`pack_key`: `small` / `medium` / `large`, optional `quantity`).
- Stripe webhook now branches on `metadata.kind == "topup"` for `checkout.session.completed`. Top-up sessions call `CreditService.grant_topup!`, idempotent on the Stripe event id.
- Webhook falls back to expanding `line_items.data.price.metadata.credit_amount` when the session metadata is missing — keeps the system working even if the frontend was on an older build that didn't pass `credit_amount` through.
- New env vars: `STRIPE_PRICE_TOPUP_SMALL`, `STRIPE_PRICE_TOPUP_MEDIUM`, `STRIPE_PRICE_TOPUP_LARGE` (Stripe Price IDs for the three pack sizes).

### Added — Phase 1 of usage-based AI pricing

- AI credit ledger (`credit_transactions` table) — immutable record of every grant, spend, expire, and refund of AI credits.
- `users.plan_credits_balance`, `users.topup_credits_balance`, `users.plan_credits_reset_at` columns — denormalized balances and current-period end.
- `CreditService` — single entry point for credit operations (`spend!`, `grant_plan!`, `grant_topup!`, `expire_plan_credits!`, `refund!`, `shadow_spend`). Spends drain plan credits first, then top-up.
- `CreditService::FEATURE_COSTS` — weighted costs per AI feature (image generation = 5, scenario builder = 10, word suggestion = 1, etc.). Server-authoritative.
- `GET /api/me/credits` — returns `{ plan, topup, total, reset_at, plan_type }` for the current user.
- `GET /api/me/credit_transactions` — paginated transaction ledger for the current user.
- `bin/rails credits:backfill` — gives every existing user an initial plan-credit grant based on their `plan_type`. Idempotent.
- `bin/rails credits:recompute_balances` — rebuilds denormalized balances from the ledger.
- Shadow-mode telemetry — `check_monthly_limit` in the API base controller now also runs `CreditService.shadow_spend` and logs divergences between the Redis-counter decision and the credit-ledger decision. **No user-visible change yet** — the Redis limiter remains the source of truth in Phase 1.

### Coming next

- **Phase 5 (optional):** Stripe Meter-based overage billing.
