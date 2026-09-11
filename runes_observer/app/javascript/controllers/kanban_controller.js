import { Controller } from "@hotwired/stimulus"

// Renders the fleet board with Mermaid, keeping the server-rendered HTML board
// as the fallback.
//
// The division of labour is deliberate: the *server* builds the board (columns,
// cards, links, and the `kanban` diagram text — see app/services/board/kanban.rb),
// so the page is correct with JavaScript disabled, and Mermaid is only a
// nicer renderer of the same data. If the vendored bundle is missing or the
// diagram fails, we keep the HTML instead of showing an error box.
export default class extends Controller {
  static targets = ["canvas", "source"]
  static values = { layout: { type: String, default: "diagram" } }

  connect() {
    if (window.mermaid) {
      this.renderDiagram()
      return
    }

    // `mermaid.min.js` is loaded with `defer`, so it can arrive after Turbo
    // has connected this controller. Render once it does.
    this.onLoad = () => this.renderDiagram()
    window.addEventListener("load", this.onLoad, { once: true })
  }

  disconnect() {
    if (this.onLoad) window.removeEventListener("load", this.onLoad)
  }

  // Switch between the diagram and the plain list. A board with sixty cards is
  // easier to read as a list, and a diagram is easier to scan at a glance.
  toggle() {
    this.layoutValue = this.layoutValue === "diagram" ? "list" : "diagram"
    this.canvasTarget.hidden = this.layoutValue === "list"
    this.element.classList.toggle("kanban--list", this.layoutValue === "list")
  }

  async renderDiagram() {
    const mermaid = window.mermaid
    if (!mermaid || !this.hasSourceTarget || !this.hasCanvasTarget) return
    if (this.canvasTarget.dataset.rendered === "mermaid") return

    try {
      if (!mermaid.__runesInitialized) {
        mermaid.initialize({
          startOnLoad: false,
          theme: "dark",
          securityLevel: "strict",
          fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif'
        })
        mermaid.__runesInitialized = true
      }

      const diagram = this.sourceTarget.textContent || ""
      if (!diagram.trim()) return

      const { svg } = await mermaid.render(`runes-board-${Date.now()}`, diagram)
      this.canvasTarget.innerHTML = svg
      this.canvasTarget.dataset.rendered = "mermaid"
      this.canvasTarget.hidden = this.layoutValue === "list"
      this.element.classList.add("kanban--diagram")
    } catch (error) {
      // Keep the server-rendered board: it is already the same information.
      console.warn("[board] Mermaid could not render the diagram; keeping the list", error)
    }
  }
}
