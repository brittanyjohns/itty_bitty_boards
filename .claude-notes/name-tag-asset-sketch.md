# Sketch: AAC name-tag artifact (design + build options)

**Date:** 2026-07-06 · **Status:** sketch — product decision pending (not a committed handoff yet)
**Context:** the one AAC Classroom Kit item with no existing template. Everything else reuses `story_time`, `word_list_board`, `safety_id`, `device_tag`, or the board→PDF path. This sketches how the name tag would work and where it should live.
**Rails it would ride on:** `app/services/communicators/base_asset_generator.rb` (Grover HTML→PNG/PDF + `rqrcode` QR + `asset_export` layout), the same pattern behind `GenerateDeviceTag` / `GenerateSafetyIdCard`. Template conventions: inline-styled ERB, fixed-px canvas, brand purple `#7c3aed`, `@logo` / `@avatar_data_url` / `@qr_data_url` / `@display_name` locals.

## What a name tag is

A small "meet me" card that introduces a communicator and how they talk: name, photo (optional), a friendly line ("Here's how I communicate"), a couple of core symbols, and a **QR to the communicator's MySpeak page**. For substitutes, specials teachers, new paras. Desk-tag / lanyard-card sized — much smaller than the device tag, so the classroom version wants **several per sheet**.

## Two variants — and which to build first

There are genuinely two products here. They share markup but differ in data source and scope.

### A) Generic / blank classroom sheet — **build this first (unblocks the kit)**
- No specific child, no Profile, no per-user data. A fillable card the teacher writes names on (or types before printing).
- QR is generic → `speakanyway.com/classroom` (or `/myspeak` info), UTM `utm_content=name_tag`.
- Rendered **N-up on Letter** (e.g. 8 cards, 2×4) so a teacher prints one sheet for the whole class.
- Zero per-profile plumbing: a standalone template rendered on demand — either a small backend endpoint/rake, or (cleaner for the kit) an artifact in the printables **marketing-artifact generator** (reuses Grover-free path: it just needs an HTML→PDF render). No migration, no app change.

### B) Per-communicator "Meet [Name]" card — **fast follow, becomes a real app feature**
- Profile-driven, exactly like `device_tag`: pulls `display_name`, `avatar_data_url`, and QR → `profile.public_url` (the communicator's MySpeak page).
- Joins the communicator asset family: new `Communicators::GenerateNameTag < BaseAssetGenerator`, ERB template, two new ActiveStorage attachments (`name_tag_png` / `name_tag_pdf`), wired into `Profile#generate_attachments!` and surfaced in `api/internal/profiles_controller` + `api/profiles/assets_controller` alongside the safety/device assets.
- **This is also an app feature** — parents get a printable "meet me" card for their child. High leverage: one template serves the kit, the internal API (so the printables `name_tag` product type could fetch it), AND the app.

**Recommendation:** ship A for the kit now; treat B as the product-feature version once someone confirms parents want it. Don't block the classroom sheet on the profile plumbing.

> **Product decision to flag before building B:** adding name-tag attachments to every safety Profile means `generate_attachments!` renders a third asset on every profile save (more Grover calls, a migration, and the internal `assets` block grows). Fine if it's a real feature; wasteful if the name tag is only ever a generic classroom printable. Decide A-only vs. A+B before writing B.

## Layout sketch (one card)

Landscape card, ~1050×675 px at export scale (prints crisp at ~3.5"×2.25" lanyard size; scale the canvas, keep the 14:9-ish ratio). Sections:

```
┌───────────────────────────────────────────────┐
│  [SpeakAnyWay logo]        Hi! My name is       │  ← top brand strip (purple gradient rule)
│                                                 │
│   ┌────────┐   ┌──────────────┐   ┌─────────┐   │
│   │ avatar │   │   NAME        │   │  QR     │   │
│   │ (opt.) │   │  (big, bold)  │   │ scan →  │   │
│   └────────┘   │ "Here's how   │   │ MySpeak │   │
│                │  I talk"      │   └─────────┘   │
│   [○ core symbol row: hi · more · help · stop]  │  ← optional strip
│                                                 │
│  Scan to meet me on SpeakAnyWay   speakanyway.com│  ← footer
└───────────────────────────────────────────────┘
```

- **Name** is the hero (largest element), like the device tag's `@display_name`.
- **Avatar** optional (variant B has it from the profile; variant A leaves a blank circle or omits).
- **Core symbol row** optional — a few high-frequency words (hi, more, help, stop, yes, no) as tiny cells so an unfamiliar adult sees "this is how they point to talk." Static art for A; could pull real cell images for B later.
- **QR** → MySpeak page (B) or `/classroom` (A). Copy: "Scan to meet me."
- Brand: reuse the device-tag palette (`#7c3aed` purple → `#3b82f6` blue), the top gradient rule, `SpeakAnyWay™` eyebrow. Display bare `speakanyway.com` in the footer per brand rules.

## Skeleton ERB (shared, mirrors device_tag.html.erb conventions)

```erb
<%# app/views/communicators/assets/name_tag.html.erb — ONE card.
    For the classroom sheet, wrap N of these in a CSS grid on a Letter page. %>
<div style="width:1050px;height:675px;padding:22px;
     background:linear-gradient(135deg,#f8fbff,#fdfaff);color:#1e293b;">
  <div style="height:100%;border-radius:28px;background:#fff;
       border:1px solid #e2e8f0;box-shadow:0 18px 48px rgba(15,23,42,.10);
       padding:22px;display:flex;flex-direction:column;">
    <div style="height:8px;background:linear-gradient(90deg,#8b5cf6,#6366f1,#3b82f6);
         border-radius:8px;margin:-4px -4px 14px;"></div>

    <div style="display:flex;align-items:center;justify-content:space-between;">
      <% if @logo.present? %>
        <img src="data:image/png;base64,<%= @logo %>" style="height:34px;" />
      <% end %>
      <div style="font-weight:800;letter-spacing:.08em;text-transform:uppercase;
           color:#7c3aed;font-size:14px;">Hi! My name is</div>
    </div>

    <div style="flex:1;display:grid;grid-template-columns:0.9fr 1.6fr 1fr;
         gap:16px;align-items:center;">
      <div style="text-align:center;">
        <% if @avatar_data_url.present? %>
          <img src="<%= @avatar_data_url %>"
               style="width:150px;height:150px;border-radius:999px;object-fit:cover;
                      border:6px solid #fff;box-shadow:0 8px 20px rgba(99,102,241,.18);" />
        <% end %>
      </div>

      <div>
        <div style="font-size:46px;font-weight:900;line-height:1.05;color:#0f172a;
             word-break:break-word;"><%= @display_name.presence || "___________" %></div>
        <div style="font-size:18px;color:#475569;margin-top:8px;">
          <%= @tagline.presence || "Here's how I communicate." %>
        </div>
      </div>

      <div style="text-align:center;">
        <% if @qr_data_url.present? %>
          <img src="<%= @qr_data_url %>" style="width:150px;height:150px;" />
        <% end %>
        <div style="font-size:13px;font-weight:800;color:#64748b;
             text-transform:uppercase;letter-spacing:.08em;margin-top:6px;">Scan to meet me</div>
      </div>
    </div>

    <div style="display:flex;justify-content:space-between;font-size:13px;
         color:#94a3b8;font-weight:700;">
      <span>Scan to meet me on SpeakAnyWay</span><span>speakanyway.com</span>
    </div>
  </div>
</div>
```

## Build shape for variant B (when/if approved)

Mirror `GenerateDeviceTag` almost exactly:
1. `app/services/communicators/generate_name_tag.rb` → `Communicators::GenerateNameTag < BaseAssetGenerator`, `PNG_WIDTH/HEIGHT`, `call(regenerate:)`, `attached_and_fresh?` signature cache, `template_locals` reading `profile.device_tag_display_name` (or a new `name_tag_display_name`), `avatar_data_url`, `qr_data_url_for(profile.public_url)`, `@tagline`.
2. `app/views/communicators/assets/name_tag.html.erb` (above).
3. Migration: `name_tag_png` / `name_tag_pdf` ActiveStorage attachments on Profile.
4. Add to `Profile#generate_attachments!` and the `attachment_urls` blocks in `api/internal/profiles_controller.rb` + `api/profiles/assets_controller.rb`.
5. Specs: a generator spec (renders + attaches, signature caching) mirroring the device-tag/safety-card specs; a request spec asserting the new URLs appear.

For variant A (classroom sheet) none of steps 3–4 apply — it's a data-less render (optionally an N-up wrapper) and the cleanest home is the printables **marketing-artifact generator** (it already produces kit PDFs), or a tiny backend endpoint if you'd rather keep all asset rendering server-side.

## Open questions for Brittany

1. **A-only or A+B?** Is the "Meet [Name]" card a real parent-facing app feature (build B, joins the profile assets), or is the name tag purely a classroom printable (A only)?
2. **Symbol row:** include the little core-word symbols on the card, or keep it name + photo + QR for simplicity in v1?
3. **Sheet layout for A:** how many per Letter page — 8-up (business-card size) or 6-up (roomier)?
