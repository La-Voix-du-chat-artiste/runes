# frozen_string_literal: true

# Minimal declaration runtime for the L3 conformance gate
# (docs/FLEET_DSL.md §11): just enough surface for a `.fleet.rb` file to
# compile AND run under Spinel, standing in for the real loader — which
# stays CRuby-only by design (it needs Prism and instance_eval of source
# strings, both outside Spinel's documented surface). Compiled kernels
# bake the *loaded world* instead, the same pattern as workflows.
#
# The event carries benign values (score 0.9 passes the example's guards)
# so rule bodies execute their actions against the stub context. If a
# future fleet file reads an event field not listed here, the gate fails
# to compile — add the field, deliberately: the stub is the gate's
# record of the supported guard vocabulary.
class FleetGateEvent
  def score
    0.9
  end

  def email
    "ada@example.fr"
  end

  def name
    "acme"
  end

  def country
    "FR"
  end

  def risk
    "low"
  end

  def contact
    "acme"
  end

  def agent
    "scraper"
  end

  def tool
    "fs_write"
  end

  def action
    "write"
  end

  def mission
    "weekly"
  end
end

# The binding rule bodies execute in: provides the §6 helpers and the
# §5.4 actions as no-ops (the gate proves compilation and execution shape,
# not semantics — semantics are pinned by the CRuby suite).
class FleetGateContext
  def next!
    nil
  end

  def fact(_name)
    "professional"
  end

  def task(_target, _prompt, **_opts)
    nil
  end

  def publish(_channel, _payload)
    nil
  end

  def notify(_text, level: :info)
    level
  end
end

class FleetGateAgent
  def model(_name, **_opts); end

  def tools(_grants); end

  def workspace(_path); end

  def identity(_path); end

  def concurrency(_n); end
end

# World-level declarations: INSTANCE methods. `fleet` runs the block via
# instance_eval (block form — supported by Spinel) on a world instance,
# which binds the declarations as bare calls. (instance_eval on a Class
# receiver is NOT supported by Spinel — the world is an instance.)
class FleetGateWorld
  def initialize
    @event = FleetGateEvent.new
  end

  def description(_text); end

  def transport(_kind); end

  def group(_name); end

  def config(hash = nil, **_kw); end

  def schema(_id, _spec); end

  def agent(_id, &block)
    instance = FleetGateAgent.new
    instance.instance_eval(&block) if block
  end

  def channel(_id, _topic, schema: nil, retain: false); end

  def route(*_roles, **_kw); end

  def fact(_id, _value); end

  def schedule(_id, cron: nil, interval: nil); end

  def on(_source, guard: nil, &block)
    return unless block

    context = FleetGateContext.new
    # Guards arrive as lambdas. Spinel (2026.09.12+4528) compiles
    # instance_exec with a &lambda but the call is not wired at runtime
    # (NoMethodError) — so the lambda is invoked through a literal block
    # here. Guards that call fact() are out of the gate's vocabulary for
    # now: a top-level fallback would shadow the world's own fact()
    # declaration inside the instance_eval'd block (bare calls resolve to
    # the top-level def there), which is itself a Spinel divergence we
    # are not papering over in the stub.
    context.instance_exec(@event) { |e| guard.call(e) } if guard
    context.instance_exec(@event, &block)
  end
end

# The one top-level form a fleet file uses.
def fleet(_name, &block)
  FleetGateWorld.new.instance_eval(&block) if block
end
