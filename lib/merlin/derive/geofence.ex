defmodule Merlin.Derive.Geofence do
  @moduledoc """
  Turns a position into a zone.

  This is the module half of "modules are abstraction layers, rules are data".
  A rule never sees a coordinate; it says `person.owner.zone == :home`. The
  geometry, the hysteresis and the staleness handling live here, and the zone
  definitions live in config -- which is exactly the split you asked for:
  *"modules prevent me from needing to say 'the state of the car is away when
  the GPS is <foo>', but in the data I want to say 'home is n feet around
  lat, long'"*.

  ## What it fixes

  `user_location.py` did this inline, and got three things wrong that mattered:

    * **the tri-state.** Line 124 produced `""` when the phone was outside
      every region, while `alerts.py` and `livingroom_lamps.py` both tested
      `is False`. `"" is False` is `False`, so the entire away path was dead
      code. Here the answer is `:unknown`, which is neither `:home` nor
      "not home" and cannot be mistaken for either.
    * **staleness.** Both GPS sources recorded a `checkin` timestamp that
      nothing ever read, so a phone that last reported three days ago counted
      as current. Here a stale position derives `:unknown`.
    * **flapping.** One hard threshold and no hysteresis. See `Merlin.Zones`.

  ## Recomputation

  Subscribes to its own position facts only. `user_location.py` recomputed on
  *every* state change from *every* hook -- door contacts, button presses,
  printer requests -- and then wrote its own outputs, so it re-entered itself
  and terminated only because the dedup happened to converge.
  """

  use GenServer
  require Logger

  alias Merlin.{Fact, World, Zones}

  defstruct [
    :id,
    :lat_path,
    :lon_path,
    :out_path,
    :out_position_path,
    :stale_after_ms,
    :accuracy_path,
    :max_accuracy_m,
    :max_speed,
    :certainty_timer,
    :unknown_recheck_ms,
    recheck_armed?: false
  ]

  # Fifteen seconds, not sixty. This is how long the house does not know where
  # someone is after their tracker resumes, and a minute of that is long enough
  # for a rule to make the wrong decision. Four self-sent messages a minute per
  # geofence costs nothing.
  #
  # Overridable per geofence so a test can use milliseconds rather than
  # spending a quarter of a minute proving a timer works.
  @unknown_recheck_ms 15_000

  @doc false
  def start_link(spec), do: GenServer.start_link(__MODULE__, spec, name: via(spec.id))

  defp via(id), do: {:via, Registry, {Merlin.Derive.Registry, {__MODULE__, id}}}

  @impl true
  def init(spec) do
    state = %__MODULE__{
      id: spec.id,
      lat_path: spec.lat,
      lon_path: spec.lon,
      out_path: spec.out,
      out_position_path: spec[:out_position],
      stale_after_ms: spec[:stale_after_ms],
      accuracy_path: spec[:accuracy],
      max_accuracy_m: spec[:max_accuracy_m],
      max_speed: spec[:max_speed],
      unknown_recheck_ms: spec[:unknown_recheck_ms] || @unknown_recheck_ms
    }

    Merlin.Bus.subscribe(state.lat_path)
    Merlin.Bus.subscribe(state.lon_path)

    # The accuracy fact too, which it never did.
    #
    # Without this the accuracy gate was permanently one message behind: a
    # message's coordinates triggered a recompute while the accuracy fact still
    # held the PREVIOUS fix's value, and the accuracy arriving triggered
    # nothing at all. So `max_accuracy_m: 100` judged every fix by the accuracy
    # of the one before it, and a 500m fix was placed in a zone as confidently
    # as a 5m one. The moduledoc's claim that a vague fix "is not evidence of
    # being anywhere in particular" was simply not implemented.
    if state.accuracy_path, do: Merlin.Bus.subscribe(state.accuracy_path)

    # Compute once at start so a restart does not leave the zone stale until
    # the next fix arrives.
    state = recompute(state)

    {:ok, state}
  end

  @impl true
  def handle_info({:merlin, %Merlin.Change{}}, state) do
    {:noreply, recompute(state, arm_recheck: true)}
  end

  # The deferred second look. See `@recheck_ms`.
  def handle_info(:recheck, state) do
    {:noreply, recompute(%{state | recheck_armed?: false}, arm_recheck: false)}
  end

  # The subject could now be somewhere else. See `certainty_window_ms/3`.
  def handle_info(:certainty_lapsed, state) do
    {:noreply, recompute(%{state | certainty_timer: nil}, arm_recheck: false)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  Compute the zone for a position, without any process involved.

  Exposed because the truth table is worth testing as a pure function rather
  than by driving a GenServer and waiting.
  """
  @spec compute(Merlin.Geo.point() | :unknown, atom() | :unknown, %{atom() => Zones.zone()}) ::
          atom() | :unknown
  def compute(point, previous, zones), do: Zones.resolve(point, previous, zones)

  # A message's last fact write does not reliably produce a change.
  #
  # `World.put/3` notifies on change only, and a phone that reports a constant
  # nominal accuracy -- most of them -- writes the same value every time. So
  # the sequence is: lat changes (partial, hold), lon changes (partial, hold),
  # accuracy written but IDENTICAL, no notification, no third recompute. The
  # zone then freezes until a fix happens to arrive with a different accuracy.
  #
  # This is a failure the contemporaneity fix introduced, and the tests for
  # that fix are what caught it. So: an incoherent read arms one deferred
  # recheck. By the time it fires the rest of the message has landed and the
  # components agree. It does not re-arm itself, so a genuinely partial
  # observation holds once and stops rather than spinning.
  @recheck_ms 50

  # How long a fix keeps being an answer.
  #
  # `stale_after` alone is a guess: thirty minutes is neither long enough to be
  # generous nor short enough to be safe, and it says nothing about geography.
  # The question a rule actually asks is "could he be somewhere else by now",
  # and that is answerable -- distance to the nearest other zone, divided by
  # the fastest he could plausibly travel.
  #
  # Straight-line, so it is a genuine lower bound: no route is shorter than the
  # great circle. If it says the hackspace is eight minutes from home and four
  # have passed, he certainly has not arrived, whatever road he took.
  #
  # This is not hypothetical. A phone went flat at the hackspace at 23:23; the
  # car came home at 00:24; a door opened at 00:27; and the intruder latch
  # fired, because the zone still said `:hackspace` an hour after anyone could
  # possibly know that. Without a declared `max_speed` the behaviour is
  # unchanged, so this costs nothing to leave out.
  defp certainty_window_ms(_point, _zone, %{max_speed: nil}), do: :infinity

  defp certainty_window_ms(point, zone, state) do
    mps = Merlin.Geo.to_mps(state.max_speed)

    others =
      Zones.all()
      |> Enum.reject(fn {id, _z} -> id == zone end)

    cond do
      mps <= 0 ->
        :infinity

      others == [] ->
        # Nowhere else to be, so the answer cannot become wrong this way.
        :infinity

      true ->
        others
        |> Enum.map(fn {_id, z} ->
          # To the EDGE of the other zone, not its centre: arriving means
          # getting inside it.
          metres = max(Merlin.Geo.distance(point, z.center) - z.radius_m, 0.0)
          round(metres / mps * 1_000)
        end)
        |> Enum.min()
    end
  end

  # While the answer is :unknown, re-read on a timer.
  #
  # `World.put/3` notifies on CHANGE, and a parked car reports the same
  # coordinates every two minutes -- so fresh, perfectly good fixes arrive
  # that publish nothing. Once the certainty window had expired the zone
  # therefore stayed :unknown for ever, and a car sitting in the drive being
  # tracked correctly read as unlocatable for four hours.
  #
  # The same trap as the accuracy fact in M7, reached from the other side: any
  # design that only reacts to changes is blind to a value that is refreshed
  # without changing. So whenever the published answer is :unknown, look again
  # shortly -- a fix whose observed_at has advanced restores the zone even
  # though its value never moved.
  defp schedule_unknown_recheck(state) do
    state = cancel_certainty(state)
    ref = Process.send_after(self(), :certainty_lapsed, state.unknown_recheck_ms)
    %{state | certainty_timer: ref}
  end

  @doc "The default interval for re-reading while the subject cannot be placed."
  @spec unknown_recheck_ms() :: pos_integer()
  def unknown_recheck_ms, do: @unknown_recheck_ms

  # Only ever called with a finite remaining window: the :infinity case is
  # decided before this, in recompute.
  defp schedule_certainty(state, window_ms) when is_integer(window_ms) do
    state = cancel_certainty(state)
    ref = Process.send_after(self(), :certainty_lapsed, max(window_ms, 50))
    %{state | certainty_timer: ref}
  end

  defp cancel_certainty(%{certainty_timer: nil} = state), do: state

  defp cancel_certainty(%{certainty_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | certainty_timer: nil}
  end

  defp recompute(state, opts \\ []) do
    previous = World.get(state.out_path, :unknown)

    case read_point(state) do
      :incoherent ->
        # HOLD. Not `:unknown` -- writing that would itself be an edge, and
        # `{:leaves, zone, :home}` fires on it just as readily as a real
        # departure would. The whole defect here is edges that describe
        # nothing that happened.
        #
        # Debug, not info: this is the NORMAL path for the first writes of
        # every message, so at any louder level it would be pure noise.
        Logger.debug(fn -> "#{state.id}: partial observation, holding" end)

        if Keyword.get(opts, :arm_recheck, false) and not state.recheck_armed? do
          Process.send_after(self(), :recheck, @recheck_ms)
          %{state | recheck_armed?: true}
        else
          state
        end

      :unknown ->
        # No usable fix at all -- absent, stale or too vague. Distinct from
        # `:incoherent`, which holds; this one publishes, because "we cannot
        # place him" is an answer and rules decline on it.
        if previous != :unknown do
          Logger.info("#{state.id}: #{inspect(previous)} -> :unknown")
        end

        World.put(state.out_path, :unknown, source: {:derive, state.id})

        if state.out_position_path do
          World.put(state.out_position_path, :unknown, source: {:derive, state.id})
        end

        # Keep looking. A poller that resumes reporting the same coordinates
        # refreshes observed_at without publishing anything, so waiting for a
        # change would wait for ever.
        schedule_unknown_recheck(state)

      {point, fix_at} ->
        do_recompute(state, previous, point, fix_at)
    end
  end

  defp do_recompute(state, previous, point, fix_at) do
    resolved = Zones.resolve(point, previous, Zones.all())
    window = certainty_window_ms(point, resolved, state)
    age = System.monotonic_time(:millisecond) - fix_at

    {zone, state} =
      cond do
        window == :infinity and resolved == :unknown ->
          {resolved, schedule_unknown_recheck(state)}

        window == :infinity ->
          {resolved, cancel_certainty(state)}

        age >= window ->
          # He could be somewhere else by now, so this fix is no longer an
          # answer. :unknown rather than the last zone: rules act on a zone
          # and decline on :unknown, which is the whole point.
          if resolved != :unknown do
            Logger.info(
              "#{state.id}: #{inspect(resolved)} is no longer certain -- the fix is " <>
                "#{div(age, 1000)}s old and somewhere else has been reachable for " <>
                "#{div(age - window, 1000)}s"
            )
          end

          {:unknown, schedule_unknown_recheck(state)}

        true ->
          {resolved, schedule_certainty(state, window - age)}
      end

    if zone != previous do
      Logger.info("#{state.id}: #{inspect(previous)} -> #{inspect(zone)}")
    end

    World.put(state.out_path, zone, source: {:derive, state.id})

    # The position as a single point, so expressions can use distance/2 and
    # within?/3 without knowing it arrived as two separate facts. This is what
    # lets "is the car with my phone" be a line of config rather than a module.
    if state.out_position_path do
      World.put(state.out_position_path, point, source: {:derive, state.id})
    end

    state
  end

  # How far apart two components of one observation may be observed and still
  # be treated as describing the same moment.
  #
  # The assumption, stated so it can be checked: one message's fact writes
  # complete within this window, and two distinct observations are further
  # apart than it. Both hold by orders of magnitude -- three consecutive calls
  # to one writer doing ETS inserts take well under a millisecond, and a phone
  # reports every thirty seconds.
  #
  # Where it fails is two genuine observations less than 250ms apart, whose
  # components could still be crossed. That is a duplicate message in practice,
  # where the chimera equals the truth and nothing is harmed.
  @coherence_ms 250

  # A position is only usable if its components are present, fresh, accurate
  # enough, and -- the part this did not check -- **contemporaneous**.
  #
  # One phone message becomes three fact writes: lat, lon, accuracy. Between
  # them the world holds a position that never existed: a new latitude beside
  # the previous longitude, or new coordinates beside a stale accuracy. The
  # geofence recomputed on each of those, and every intermediate result is an
  # edge that edge-triggered rules act on.
  #
  # Tier 9 caught it as the intruder latch re-arming: a phone arriving home
  # with a 120m fix briefly read `:home` using the PREVIOUS accuracy, which
  # matched `{:enters, zone, :home}`, and only then did the accuracy fact land
  # and drop the zone to `:unknown`. The same phantom can turn the lamps on for
  # an arrival that did not happen, and it occurs on every single update -- it
  # is merely invisible when the chimera lands in the same zone as the truth.
  #
  # Contemporaneity is checkable because an unchanged write still refreshes
  # `observed_at`. A device re-reporting an identical longitude therefore keeps
  # the pair coherent, which is that decision paying for itself somewhere it
  # was not designed for.
  #
  # The trade-off, stated: a device that DECLARES an accuracy fact and then
  # stops sending it freezes its zone, because the fix can no longer be
  # verified. That is deliberate and it is the safer direction -- the
  # alternative is placing someone using a fix of unknown quality, which is the
  # defect above wearing a different hat. It is also visible: the zone simply
  # stops changing, and the debug line below says why. A device that never
  # reports accuracy at all is unaffected, since there is no fact to be
  # incoherent with.
  defp read_point(state) do
    with {:ok, lat, lat_at} <- fresh_value(state.lat_path, state.stale_after_ms),
         {:ok, lon, lon_at} <- fresh_value(state.lon_path, state.stale_after_ms),
         :ok <- coherent?([lat_at, lon_at | accuracy_observed_at(state)]),
         :ok <- accurate_enough(state) do
      # The older of the two components is when this fix was taken, and it is
      # what the certainty window is measured from.
      {{lat, lon}, min(lat_at, lon_at)}
    else
      :incoherent -> :incoherent
      _ -> :unknown
    end
  end

  defp coherent?(stamps) do
    if Enum.max(stamps) - Enum.min(stamps) <= @coherence_ms, do: :ok, else: :incoherent
  end

  defp accuracy_observed_at(%{accuracy_path: nil}), do: []

  defp accuracy_observed_at(state) do
    case World.fetch(state.accuracy_path) do
      {:ok, %Fact{observed_at: at}} -> [at]
      :error -> []
    end
  end

  @doc "How far apart an observation's components may be and still be paired."
  @spec coherence_ms() :: pos_integer()
  def coherence_ms, do: @coherence_ms

  @doc """
  How long after a partial observation the deferred recheck runs.

  Exposed so a test can wait for it deterministically rather than guessing.
  A test that sleeps less than this asserts on a zone that was still going to
  change, which is a flake that looks exactly like a bug.
  """
  @spec recheck_ms() :: pos_integer()
  def recheck_ms, do: @recheck_ms

  defp fresh_value(path, stale_after_ms) do
    case World.fetch(path) do
      {:ok, %Fact{value: value} = fact} when is_number(value) ->
        cond do
          Fact.stale?(fact) -> :stale
          is_integer(stale_after_ms) and Fact.age(fact) > stale_after_ms -> :stale
          true -> {:ok, value, fact.observed_at}
        end

      _ ->
        :absent
    end
  end

  defp accurate_enough(%{accuracy_path: nil}), do: :ok
  defp accurate_enough(%{max_accuracy_m: nil}), do: :ok

  defp accurate_enough(state) do
    # A 2km-accurate fix is not evidence of being anywhere in particular. The
    # Python captured gpsAccuracy and never looked at it.
    case World.get(state.accuracy_path) do
      n when is_number(n) and n <= state.max_accuracy_m -> :ok
      nil -> :ok
      _ -> :too_vague
    end
  end
end
