require_relative 'test_helper'

class TestVMManager < Minitest::Test
  def setup
    # Auto mode on a non-existent path should fall back to mock.
    @manager = Runes::WASM::VMManager.new('non_existent.wasm', pool_size: 2, backend: :auto)
  end

  def test_pool_initialization
    assert_equal 2, @manager.size
  end

  def test_acquire_and_release
    vm = @manager.acquire
    refute_nil vm
    assert_equal 1, @manager.size

    @manager.release(vm)
    assert_equal 2, @manager.size
  end

  def test_mock_backend_for_missing_binary
    vm = @manager.acquire
    assert vm.mock?
    @manager.release(vm)
  end

  def test_mock_run_round_trip
    vm = @manager.acquire
    res = vm.run("puts 'hi'")
    assert res[:ok]
    assert_includes res[:stdout], '[mock]'
    assert res[:mock], 'mock results must be marked (W6)'
    @manager.release(vm)
  end

  def test_double_release_is_ignored
    vm = @manager.acquire
    @manager.release(vm)
    size_before = @manager.size
    @manager.release(vm) # double release must not corrupt the pool (W4)
    assert_equal size_before, @manager.size
    # The pool must still be usable: with_vm re-releases safely.
    @manager.with_vm { |v| assert v.mock? }
  end

  # The lease must survive repeated acquire/release cycles — release
  # un-marks and acquire re-marks, or the pool drains after one cycle
  # (found live with the real ruby.wasm backend).
  def test_with_vm_cycles_repeatedly
    5.times do |i|
      @manager.with_vm do |vm|
        refute_nil vm
        assert vm.run("puts #{i}")[:ok]
      end
      assert_equal 2, @manager.size, "pool must not drain (cycle #{i})"
    end
  end
end
