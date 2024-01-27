import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="pwa--sync"
export default class extends Controller {
  connect() {
    // same as above, we declare a db and online status
  }

  async sync() {
    if (await this.db.forms.count() == 0 && !this.connected) return

    const forms = await db.table('forms').toArray() // this is Dexie syntax
    const formsIdsToRemove = []
    for (let form of forms) {
      const response = await fetch(form.url, {
        method: form.method,
        headers: { 'Content-Type': 'application/json' },
        body: form.body
      })
      if (response.ok) {
        formsIdsToRemove.push(form.id)
      }
    }
    await db.forms.bulkDelete(formsIdsToRemove)
  }

  async displayOfflineForms() {
    const forms = await this.db.table('forms').toArray()
    forms.forEach(async (form) => {
      if (!this.listItemExists(form)) {
        this.listContainerTarget.innerHTML += (this.listItem(form))
      }
      if (this.formExistsInServer(form)) { this.removeSyncedItem(form) }
    })
  }

  listItem(form) {
    const template = this.listItemTemplateTarget.innerHTML
    const rendered = Mustache.render(template, {
      name: form.name,
      dom_id: form.id
    })
    return rendered
  }
}
