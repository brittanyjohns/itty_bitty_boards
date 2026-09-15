# Printable products (non-board printables)

A printable sold as its own product rather than as a board, starting with AAC
**device tags**: an editable Canva template in several designs ("Voice Tag 1",
"Voice Tag 2", "Name Tag", "Mini Core Board"), 2.5 x 2 in, where the buyer adds
their own QR. Issue #957.

`BoardPrintable` is board-only: it walks a board tree and renders pages. A
device tag's art is *designed* in Canva, not rendered from a board, so it gets
its own record. Scene mockups of it reuse the scene engine
(`scene-engine.md`).

## The model: `PrintableProduct`

| column | |
|---|---|
| `name`, `description`, `size_label` | admin copy (`size_label` e.g. "2.5 x 2 in") |
| `slug` | unique, kebab-case. Derived from the name when blank, and a typed slug is parameterized rather than refused |
| `category` | allowlist `CATEGORIES`, today only `device_tag`. Each category must also be a `SceneTemplate::CATEGORIES` value, because a product composites only into scenes of its own category (`scene_template_category`) |
| `status` | `draft` / `ready` / `archived`. Archive, never destroy |
| `canva_templates` | jsonb `[{label, description, url}]`, max 8 |

### Named attachments, never one bag

| attachment | what | allowlist |
|---|---|---|
| `artworks` | the product's design images. Source art for scene mockups. Never a buyer file | png/jpeg/webp, 25 MB, 20 files |
| `downloads` | what a buyer receives | pdf/png, 50 MB, 5 files (Etsy's per-listing cap) |

This is the `board_printables.files` lesson from CLAUDE.md: one collection
partitioned by blob metadata once handed a listing video to a buyer as the
product. Here an artwork can't become a download because `downloads` is a
different collection.

Each file's admin **label** is in blob metadata (`metadata["label"]`, capped at 80
chars), the same way `KitPage` labels documents. With no label, the file name
without its extension is used (`artwork_label` / `download_label`).

Writes go through `attach_artwork!` / `attach_download!`. They check type, size
and count **before** uploading anything, store at a versioned key
(`printable_products/<id>/<hex>/<file>`, since CloudFront caches by path), and
purge the blob if the attach's save fails. The `attachments_allowed` validation
is the backstop for any other write path.

### Canva links: one allowlist, shared

`CanvaTemplatesValidator` (`app/validators/`) is the https +
`canva.com/design/…` / `canva.link/…` allowlist. It was extracted from `KitPage`,
which now declares `validates :canva_templates, canva_templates: { max: 5 }` and
keeps its `CANVA_*` constants as aliases of the validator's. Never copy the URL
check into a third model; add another `validates` line.

## Scene mockups of a product

`SceneComposition.owner` may be a `PrintableProduct`
(`has_many :scene_compositions, as: :owner, dependent: :destroy`).

- **Art sources per owner** (`SceneComposition::SOURCES_FOR_OWNER`, an allowlist):
  a product may use `product_artwork` and `upload`, and a board printable may use
  `page_thumbnail`, `device_screen` and `upload`. Neither may use the other's
  sources, on save or at render.
- `product_artwork: {blob_id}` must name one of the owner's `artworks`. It is
  validated on save, and `RenderSceneComposition` checks it again at render
  against the owner's artworks as they are then.
- The template picker offers calibrated templates in the product's category only.
- The render digest includes each drawn artwork blob's checksum.
- **Removing an artwork a mockup draws is refused** in the admin
  (`compositions_using_artwork`). Change those slots first. This is the same
  restrict-don't-cascade rule `SceneTemplate` keeps.

Artwork is composited in Chrome and is **never sent to an image model**.

## Admin

- `/admin/printable_products` (Content menu, next to Scene Templates): index
  (archived hidden by default), new/create, edit/update (the Canva link
  repeater), `archive`.
- `/admin/printable_products/:id` (show): artwork uploads with labels, downloads,
  Canva links, and a "Scene mockups" card. The upload and remove forms are side
  forms that report errors as a flash.
- `/admin/printable_products/:id/scene_compositions/...`:
  `Admin::PrintableProductSceneCompositionsController` subclasses
  `Admin::SceneCompositionsController`. It overrides only how the owner is found
  and the path helpers, and it **shares the views**. The form offers each slot
  `slot.accepts & composition.allowed_sources`. The artwork picker posts
  `artwork_blob_id`, which the controller maps onto `blob_id` only for the
  `product_artwork` source, so it can't collide with the uploaded-picture select.

## Not here yet

Etsy listings and a curated gallery for products are a follow-up (it builds on
#961 and #963). The rule it inherits is **drafts only**: Rails creates a draft
and never activates one (`board-printables-etsy.md`). Keep attachments named
when it lands: a listing's gallery should *reference* renders and artworks, not
copy them into a shared bag.
