require "test_helper"

class DemoFabricTest < ActiveSupport::TestCase
  test "seed! produces a realistic fleet with both live and ended agents" do
    DemoFabric.seed!

    assert_equal 2, Agent.count
    assert_equal 1, Agent.online.count
    assert_equal 1, Agent.ended.count
    assert_operator Packet.count, :>, 20

    kinds = Packet.distinct.pluck(:kind)
    %w[card status prompt progress response response_global journal tool_request].each do |kind|
      assert_includes kinds, kind
    end
    assert_equal 3, Packet.of_kind("prompt").count
  end

  test "the demo invents none of the deleted claim/lease protocol" do
    DemoFabric.seed!

    %w[claim started session_claim session_started].each do |kind|
      assert_equal 0, Packet.of_kind(kind).count, kind
    end
    assert_empty Packet.where("topic LIKE 'runes/sessions%'")
    assert_empty Packet.where("topic LIKE '%/claim'")
    assert_empty Packet.where("topic LIKE '%/started'")
  end

  test "seed! is repeatable and self-cleaning" do
    DemoFabric.seed!
    once = Packet.count
    agents = Agent.count

    DemoFabric.seed!

    assert_equal once, Packet.count
    assert_equal agents, Agent.count
  end

  test "every seeded request is fully attributable" do
    DemoFabric.seed!

    request_ids = Packet.where.not(request_id: nil).distinct.pluck(:request_id)
    assert_equal 3, request_ids.size

    request_ids.each do |request_id|
      rows = Packet.for_request(request_id)
      assert_operator rows.count, :>=, 4, request_id
      assert_equal rows.count, rows.where.not(agent_id: nil).count, request_id
      assert_equal 1, rows.distinct.count(:agent_id), request_id
    end
  end
end
