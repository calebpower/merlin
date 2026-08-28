defmodule Merlin.ControlTest do
  @moduledoc """
  Tier 4: the operator control contract.

  The question this tier answers that no cheaper one can: given every state a
  token can be in, and every shape of command, what is permitted. That is an
  authorization matrix, and it is the same question `snitch_test.exs` asks of
  the ingress -- asked here of the surface that can turn on the heating.

  The property under test is not "a command works". It is that **the thing the
  operator confirmed is the thing that runs**, and that everything else is
  refused. A one-shot `do_this(command)` relates the description on screen to
  the effect on the house only by hope; two phases make the resolved effects
  themselves the thing that gets committed.

  ## What this tier does not prove

  That a committed effect reached the broker. That needs one, and lives in
  tier 6. Every effect here is asserted through `Merlin.Effects.Tap`, which
  reports what became of each -- so "was performed" and "was discarded by dry
  run" are distinguishable without a transport.
  """

  use ExUnit.Case, async: false

  @moduletag :tier4

  alias Merlin.Control
  alias Merlin.Control.Prepared
  alias Merlin.Effects.{Report, Tap}

  @group %{
    id: :lamps,
    members: [[:lamp, :one, :power]],
    set_topic: "z2m/lamps/set",
    encode: {:json_state, %{on: "ON", off: "OFF"}}
  }

  @members_only %{id: :exterior_doors, members: [[:door, "front", :contact]]}

  setup do
    Merlin.Config.put(%{
      groups: %{lamps: @group, exterior_doors: @members_only},
      dry_run: true
    })

    # Merlin.Control is in the application's supervision tree, so it is
    # already running; reset rather than start a second one.
    Control.reset()
    Tap.clear()
    Merlin.Settle.finish()
    :ok = Tap.subscribe()

    on_exit(fn ->
      Tap.clear()
      Merlin.Settle.finish()
      Merlin.Config.put(%{})
    end)

    :ok
  end

  # --- the allowlist --------------------------------------------------------

  describe "what may be commanded" do
    test "a group that exists and can be commanded" do
      assert {:ok, [{:set_group, :lamps, :off}]} = Control.resolve({:set_group, :lamps, :off})
    end

    test "a group that does not exist is refused" do
      assert {:error, {:unknown_group, :nope}} = Control.resolve({:set_group, :nope, :off})
    end

    test "a members-only group is refused, not silently failed" do
      # It names a set of facts and has nowhere to publish. A rule commanding
      # one is refused at boot; an operator gets the same answer rather than
      # an effect that can only fail at dispatch.
      assert {:error, {:group_not_commandable, :exterior_doors}} =
               Control.resolve({:set_group, :exterior_doors, :off})
    end

    test "a concrete topic may be published" do
      assert {:ok, [{:publish, "a/b", "ON", []}]} = Control.resolve({:publish, "a/b", "ON"})
    end

    test "a wildcard topic is refused" do
      # A subscription pattern is not an address. Some brokers accept it
      # silently and drop it, which is the worst of both.
      assert {:error, {:wildcard_topic, _}} = Control.resolve({:publish, "a/+/c", "ON"})
      assert {:error, {:wildcard_topic, _}} = Control.resolve({:publish, "a/#", "ON"})
    end

    test "a fact may be written" do
      assert {:ok, [{:set_fact, [:a, :b], 1}]} = Control.resolve({:set_fact, [:a, :b], 1})
    end

    test "an empty path is not a fact" do
      assert {:error, {:not_a_command, _}} = Control.resolve({:set_fact, [], 1})
    end

    test "anything not on the allowlist is refused" do
      # Notably: there is no eval. bin/merlind remote already exists and is
      # honest about being a shell.
      for command <- [
            {:eval, "System.halt()"},
            {:notify, :discord, "hi"},
            :restart,
            {:set_group, "lamps", :off},
            "set lamps off"
          ] do
        assert {:error, {:not_a_command, _}} = Control.resolve(command),
               "#{inspect(command)} must not be commandable"
      end
    end
  end

  # --- what needs confirming ------------------------------------------------

  describe "what needs confirming" do
    test "outward actuation does" do
      assert Control.confirmable?([{:set_group, :lamps, :off}])
      assert Control.confirmable?([{:publish, "a/b", "ON", []}])
    end

    test "writing a fact does, even though the settle window permits it" do
      # Not outward, so Settle rightly lets it through -- learning is the point
      # of the window. But a fact written by hand can wedge a latch into a
      # state that survives into the snapshot and outlives the session.
      refute Merlin.Settle.suppresses?({:set_fact, [:a], 1})
      assert Control.confirmable?([{:set_fact, [:a], 1}])
    end

    test "a log does not" do
      refute Control.confirmable?([{:log, :info, "hello"}])
    end

    test "one confirmable effect makes the batch confirmable" do
      assert Control.confirmable?([{:log, :info, "x"}, {:set_group, :lamps, :off}])
    end
  end

  # --- the token protocol ---------------------------------------------------

  describe "prepare and commit" do
    test "prepare resolves and describes, and performs nothing" do
      assert {:ok, %Prepared{} = p} = Control.prepare({:set_group, :lamps, :off})

      assert p.effects == [{:set_group, :lamps, :off}]
      assert p.description == ["set group lamps -> :off"]
      assert p.confirm?
      assert p.dry_run?

      refute_receive {:merlin_effect, %Report{}}, 50
    end

    test "commit performs exactly the prepared effects" do
      {:ok, p} = Control.prepare({:set_fact, [:ctl, :commits], 1})
      assert {:ok, [{:set_fact, [:ctl, :commits], 1}]} = Control.commit(p.token)

      assert_receive {:merlin_effect,
                      %Report{effect: {:set_fact, [:ctl, :commits], 1}, outcome: :dry_run}}
    end

    test "a token is single use" do
      {:ok, p} = Control.prepare({:set_fact, [:ctl, :single_use], 1})
      assert {:ok, _} = Control.commit(p.token)
      assert {:error, :unknown_token} = Control.commit(p.token)
    end

    test "a token minted for one command cannot commit another" do
      # The claim the whole protocol exists for: what was confirmed is what
      # runs. Two prepares, and each token redeems only its own effects.
      {:ok, a} = Control.prepare({:set_fact, [:ctl, :a], 1})
      {:ok, b} = Control.prepare({:set_fact, [:ctl, :b], 2})

      refute a.token == b.token

      assert {:ok, [{:set_fact, [:ctl, :a], 1}]} = Control.commit(a.token)
      assert {:ok, [{:set_fact, [:ctl, :b], 2}]} = Control.commit(b.token)
    end

    test "an unknown token is refused" do
      assert {:error, :unknown_token} = Control.commit("not-a-real-token")
    end

    test "another process may not redeem a token" do
      # A token is a decision made by one operator at one screen. Letting a
      # different process redeem it would make the confirmation a formality.
      {:ok, p} = Control.prepare({:set_fact, [:ctl, :wrong_pid], 1})

      parent = self()
      spawn(fn -> send(parent, {:result, Control.commit(p.token, self())}) end)

      assert_receive {:result, {:error, :wrong_requester}}
      assert Control.outstanding() == 1, "a refused commit must not consume the token"
    end

    test "cancel discards without running" do
      {:ok, p} = Control.prepare({:set_group, :lamps, :off})
      assert :ok = Control.cancel(p.token)
      assert {:error, :unknown_token} = Control.commit(p.token)
      refute_receive {:merlin_effect, %Report{}}, 50
    end

    test "a token expires, and an expired one is refused" do
      # The branch no test reached: expire/1 is swept on every call, and a
      # broken comparison there would either drop every token instantly (loud,
      # every other test fails) or never drop one at all (silent, and a command
      # left on a screen overnight stays live until morning).
      {:ok, p} = Control.prepare({:set_fact, [:ctl, :expired], 1}, self(), ttl_ms: 0)

      assert {:error, :unknown_token} = Control.commit(p.token)
      refute_receive {:merlin_effect, %Report{}}, 50
    end

    test "an unexpired token is not swept" do
      # The control for the test above. Without it, expire/1 rejecting
      # everything would pass the expiry assertion and look correct.
      {:ok, p} = Control.prepare({:set_fact, [:ctl, :unexpired], 1}, self(), ttl_ms: 60_000)

      assert {:ok, _} = Control.commit(p.token)
    end

    test "an expired token is swept even if never redeemed" do
      {:ok, _} = Control.prepare({:set_fact, [:ctl, :swept], 1}, self(), ttl_ms: 0)

      assert Control.outstanding() == 0,
             "an expired token must not sit in the table for ever"
    end

    test "a refused command mints nothing" do
      assert {:error, _} = Control.prepare({:set_group, :nope, :off})
      assert Control.outstanding() == 0
    end
  end

  # --- dry run and the override --------------------------------------------

  describe "dry run" do
    test "a commit honours the daemon's dry run by default" do
      {:ok, p} = Control.prepare({:set_fact, [:ctl, :honours_dry], 1})
      Control.commit(p.token)

      assert_receive {:merlin_effect, %Report{outcome: :dry_run}}
    end

    test "an explicit per-command override actuates for real" do
      # How an operator acts during a soak: individually consented, global
      # posture untouched. There is deliberately no runtime dry_run toggle --
      # it is snapshotted in three places and would half-apply.
      {:ok, p} = Control.prepare({:set_fact, [:ctl, :override], 2})
      Control.commit(p.token, self(), dry_run: false)

      assert_receive {:merlin_effect, %Report{outcome: :performed}}
      assert Merlin.World.get([:ctl, :override]) == 2
    end

    test "the override is per command, not sticky" do
      {:ok, a} = Control.prepare({:set_fact, [:ctl, :sticky], 3})
      Control.commit(a.token, self(), dry_run: false)
      assert_receive {:merlin_effect, %Report{outcome: :performed}}

      {:ok, b} = Control.prepare({:set_fact, [:ctl, :sticky], 4})
      Control.commit(b.token)
      assert_receive {:merlin_effect, %Report{outcome: :dry_run}}
    end
  end

  # --- attribution ----------------------------------------------------------

  describe "provenance" do
    test "a committed effect is attributed to an operator, not a rule" do
      {:ok, p} = Control.prepare({:set_fact, [:ctl, :attributed], 1})
      Control.commit(p.token, self(), who: "root@pts/0")

      assert_receive {:merlin_effect, %Report{source: {:operator, "root@pts/0"}}}
    end

    test "an operator-written fact carries that provenance into the world" do
      # The difference between "the latch fired because something happened" and
      # "somebody set it by hand at 2am", six months later.
      {:ok, p} = Control.prepare({:set_fact, [:ctl, :byhand], :fired})
      Control.commit(p.token, self(), dry_run: false, who: "root@pts/0")

      assert_receive {:merlin_effect, %Report{outcome: :performed}}
      assert {:ok, fact} = Merlin.World.fetch([:ctl, :byhand])
      assert fact.source == {:operator, "root@pts/0"}
    end
  end

  # --- the settle window applies to operators too ---------------------------

  describe "the settle window" do
    test "an operator command is held like any other outward effect" do
      # A human poking at the daemon right after a broker reconnect is not an
      # edge case, it is the normal case. A path around the window would
      # actuate into a house merlin has not learned yet.
      Merlin.Settle.begin(:test, 5_000)

      {:ok, p} = Control.prepare({:set_group, :lamps, :off})
      Control.commit(p.token, self(), dry_run: false)

      assert_receive {:merlin_effect, %Report{outcome: {:held, _}}}
    end
  end
end
