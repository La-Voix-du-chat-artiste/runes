import { Controller } from "@hotwired/stimulus"

// Drag-and-drop on a mission board (slice 3): dropping a card on a column
// POSTs the move to the server, which re-renders the mission .mmd through
// Runes::Kanban, journals it and announces it on the fabric. The DOM node is
// moved optimistically and the page reloads on failure, so the board never
// shows a state the file does not have.
export default class extends Controller {
  static values = {
    id: String,
    moveUrl: String
  }
  static targets = ["card", "column"]

  connect() {
    this.dragIndex = null
    for (const card of this.cardTargets) {
      card.addEventListener("dragstart", (e) => {
        this.dragIndex = card.dataset.cardIndex
        e.dataTransfer.effectAllowed = "move"
        e.dataTransfer.setData("text/plain", this.dragIndex)
      })
    }
    for (const col of this.columnTargets) {
      col.addEventListener("dragover", (e) => {
        e.preventDefault()
        e.dataTransfer.dropEffect = "move"
        col.classList.add("kanban-col--drop")
      })
      col.addEventListener("dragleave", () => col.classList.remove("kanban-col--drop"))
      col.addEventListener("drop", (e) => {
        e.preventDefault()
        col.classList.remove("kanban-col--drop")
        const index = this.dragIndex ?? e.dataTransfer.getData("text/plain")
        if (index === null || index === "") return
        this.move(index, col.dataset.column, col)
      })
    }
  }

  async move(index, to, columnEl) {
    const url = this.moveUrlValue.replace("__INDEX__", encodeURIComponent(index))
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          ...(token ? { "X-CSRF-Token": token } : {})
        },
        body: JSON.stringify({ to })
      })
      if (!res.ok) throw new Error(`move failed: ${res.status}`)
      const card = this.cardTargets.find(c => c.dataset.cardIndex === String(index))
      if (card) columnEl.appendChild(card)
    } catch (e) {
      window.location.reload()
    }
  }
}
