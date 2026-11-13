import { Controller } from "@hotwired/stimulus"

// The theatre: animates message particles over the server-rendered SVG graph.
// Geometry comes from data-theatre-data-value (the same Theatre::Graph#to_h
// the SVG was drawn from); live packets come from /feed?fields=1 polled like
// the packet log. A delegation (task/a2a_task with a `from`) animates along
// its edge; any other packet pulses the publishing agent's node.
export default class extends Controller {
  static values = {
    data: String,
    feedUrl: String,
    interval: { type: Number, default: 2500 }
  }
  static targets = ["canvas", "particles", "pulseCount"]

  connect() {
    this.graph = JSON.parse(this.dataValue || "{}")
    this.nodes = new Map((this.graph.nodes || []).map(n => [n.id, n]))
    this.edges = new Map()
    for (const e of this.graph.edges || []) {
      this.edges.set(`${e.from}→${e.to}`, e)
    }
    this.particles = []
    this.lastId = 0
    this.count = 0
    this.raf = null
    this.poll()
    this.timer = setInterval(() => this.poll(), this.intervalValue)
    this.tick = this.tick.bind(this)
    this.raf = requestAnimationFrame(this.tick)
  }

  disconnect() {
    clearInterval(this.timer)
    if (this.raf) cancelAnimationFrame(this.raf)
  }

  async poll() {
    try {
      const sep = this.feedUrlValue.includes("?") ? "&" : "?"
      const res = await fetch(`${this.feedUrlValue}${sep}after_id=${this.lastId}`, { headers: { "Accept": "application/json" } })
      if (!res.ok) return
      const body = await res.json()
      this.lastId = body.last_id || this.lastId
      for (const packet of body.packets || []) {
        this.react(packet)
      }
    } catch (_e) {
      // a failed poll is a skipped frame, not a stopped theatre
    }
  }

  react(packet) {
    const from = packet.from || null
    const to = packet.agent_id || null
    if ((packet.kind === "task" || packet.kind === "a2a_task") && from && to) {
      const edge = this.edges.get(`${from}→${to}`)
      if (edge) this.spawnParticle(edge)
      else if (this.nodes.has(to)) this.pulse(to)
    } else if (to && this.nodes.has(to)) {
      this.pulse(to)
    }
  }

  pulse(nodeId) {
    const node = this.nodes.get(nodeId)
    const el = this.canvasTarget.querySelector(`[data-node-id="${CSS.escape(nodeId)}"]`)
    if (!el || !node) return
    const ring = document.createElementNS("http://www.w3.org/2000/svg", "circle")
    ring.setAttribute("r", node.r)
    ring.setAttribute("class", "theatre-pulse")
    el.appendChild(ring)
    setTimeout(() => ring.remove(), 900)
    this.bump()
  }

  spawnParticle(edge) {
    const circle = document.createElementNS("http://www.w3.org/2000/svg", "circle")
    circle.setAttribute("r", 4)
    circle.setAttribute("class", "theatre-particle")
    this.particlesTarget.appendChild(circle)
    this.particles.push({ edge, t: 0, el: circle })
    this.bump()
  }

  bump() {
    this.count += 1
    if (this.hasPulseCountTarget) this.pulseCountTarget.textContent = String(this.count)
  }

  // Quadratic bezier point, matching the SVG path's Q control point.
  pointAt(edge, t) {
    const u = 1 - t
    return {
      x: u * u * edge.x1 + 2 * u * t * edge.cx + t * t * edge.x2,
      y: u * u * edge.y1 + 2 * u * t * edge.cy + t * t * edge.y2
    }
  }

  tick() {
    for (const p of this.particles) {
      p.t += 0.02
      if (p.t >= 1) {
        p.el.remove()
        p.done = true
        continue
      }
      const pt = this.pointAt(p.edge, p.t)
      p.el.setAttribute("cx", pt.x)
      p.el.setAttribute("cy", pt.y)
    }
    this.particles = this.particles.filter(p => !p.done)
    this.raf = requestAnimationFrame(this.tick)
  }
}
