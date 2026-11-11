require "test_helper"

class AlertTest < ActiveSupport::TestCase
  def test_record_dedupes_by_kind_and_subject_and_counts
    a1 = Alert.record(kind: "impersonation", subject: "writer", severity: "error")
    a2 = Alert.record(kind: "impersonation", subject: "writer", severity: "error")
    assert_equal a1.id, a2.id
    assert_equal 2, a2.count
    assert_equal a1.first_seen_at, a2.first_seen_at

    other = Alert.record(kind: "signature_failure", subject: "writer")
    refute_equal a1.id, other.id, "different kind => different row"
  end

  def test_acknowledge
    alert = Alert.record(kind: "impersonation", subject: "writer")
    refute alert.acknowledged
    alert.acknowledge!
    assert alert.reload.acknowledged
    assert_equal 0, Alert.unacknowledged.count
  end
end
