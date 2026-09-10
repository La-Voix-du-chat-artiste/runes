import { Controller } from "@hotwired/stimulus"

// Polls the JSON packet feed and prepends newly arrived rows.
//
// The server renders each row from the same partial the first page uses
// (packets#feed returns { packets: [{id, html}], last_id, stats }), so the
// live view and the initial render can never drift apart. Rows carry only a
// bounded payload summary; the full body is fetched on demand from
// /packets/:id.
//
// data-feed-url-value     /feed (fleet) or /feed?agent_id=… (agent page)
// data-feed-interval-value poll interval in ms (default 2500)
// data-feed-max-bytes-value DOM byte budget for the list (default 512 KiB)
// data-feed-target="list"  the container that receives new rows
// data-feed-target="count" optional element showing the total packet count
export default class extends Controller {
  static values = {
    url: String,
    interval: { type: Number, default: 2500 },
    maxBytes: { type: Number, default: 512 * 1024 },
    paused: { type: Boolean, default: false }
  }
  static targets = ["list", "count"]

  static MAX_NODES = 400
  static MAX_BACKOFF = 30_000

  connect() {
    this.lastId = parseInt(this.listTarget.dataset.lastId || "0", 10) || 0
    this.delay = this.intervalValue
    this.inFlight = false
    this.stopped = false
    this.schedule()
  }

  disconnect() {
    this.stopped = true
    this.cancel()
  }

  pause() { this.pausedValue = true }
  resume() { this.pausedValue = false }

  schedule() {
    this.cancel()
    this.timer = setTimeout(() => this.tick(), this.delay)
  }

  cancel() {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
  }

  // Serialise polls: the next one is only scheduled after this one settles,
  // so overlapping polls cannot re-insert the same rows or duplicate DOM ids.
  async tick() {
    this.timer = null
    await this.poll()
    if (this.stopped) return
    this.schedule()
  }

  async poll() {
    if (this.pausedValue || document.hidden || this.inFlight) return
    this.inFlight = true

    try {
      const url = new URL(this.urlValue, window.location.origin)
      url.searchParams.set("after_id", this.lastId)
      const response = await fetch(url, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
      if (!response.ok) {
        // A failing observer must not hammer the server forever.
        this.backoff()
        return
      }

      const data = await response.json()
      this.delay = this.intervalValue
      if (data.packets && data.packets.length > 0) {
        this.insert(data.packets)
        this.lastId = data.last_id
        this.listTarget.dataset.lastId = String(data.last_id)
        this.trim()
      }
      if (this.hasCountTarget && data.stats) {
        this.countTarget.textContent = data.stats.total
      }
    } catch (_error) {
      this.backoff()
    } finally {
      this.inFlight = false
    }
  }

  insert(packets) {
    const html = packets
      .filter((packet) => !document.getElementById(`packet-${packet.id}`))
      .map((packet) => packet.html)
      .join("")
    if (html) this.listTarget.insertAdjacentHTML("afterbegin", html)
  }

  backoff() {
    this.delay = Math.min(Math.max(this.delay, this.intervalValue) * 2, this.constructor.MAX_BACKOFF)
  }

  // Keep the DOM bounded by BYTES, not just node count: a row can carry a
  // 2 KiB summary, so 400 nodes is ~1 MiB of text per tab.
  trim() {
    const children = Array.from(this.listTarget.children)
    let total = children.reduce((sum, child) => sum + this.nodeBytes(child), 0)

    while (
      children.length > 0 &&
      (children.length > this.constructor.MAX_NODES || total > this.maxBytesValue)
    ) {
      const last = children.pop()
      total -= this.nodeBytes(last)
      last.remove()
    }
  }

  nodeBytes(element) {
    const text = element.outerHTML || ""
    if (typeof TextEncoder !== "undefined") return new TextEncoder().encode(text).length
    return text.length
  }
}
