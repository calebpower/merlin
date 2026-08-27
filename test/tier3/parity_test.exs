defmodule Merlin.ParityTest do
  @moduledoc """
  Tier 3: every Python hook and runner is accounted for in the shipped config.

  ## Why this rather than a cross-language vector corpus

  The plan called for fixed input/expected-output vectors consumed by both the
  Python and the Elixir, so that "same behaviour" was mechanically checked. It
  is not built that way, and the reason is specific rather than convenience:

  **Seven of the Python's behaviours are bugs, and three of its code paths have
  never executed.** A corpus recording what the Python actually does would
  encode `u_home = ""` being compared with `is False`, a 204 from Discord being
  logged as an error, and the A/C returning at the start of a printer reboot --
  and then require the Elixir to reproduce them to pass. Bug-for-bug parity is
  the opposite of what this rewrite is for.

  What is worth checking mechanically is *coverage*: that nothing was quietly
  dropped on the way across. A hook that was forgotten is invisible in review
  -- the daemon starts, the other rules work, and the missing behaviour is
  noticed the first time you need it.

  So this enumerates the Python source on disk and requires every file to be
  claimed. Behavioural equivalence, where it is wanted, is asserted directly in
  the tier that can see it: bug 7's ordering in tiers 1 and 9, the tri-state in
  tier 1, the toggle asymmetry in tier 6.

  ## What this does not prove

  That the ported behaviour is *correct* -- only that a decision was made about
  every file and recorded here. A wrong port passes this test.
  """

  use ExUnit.Case, async: true

  @moduletag :tier3

  @config_path "priv/merlin.exs"
  @python_root "merlin"

  # Every Python hook and runner, and what it became. `:deliberately_dropped`
  # is a legal answer, but it has to be written down.
  @parity %{
    "hooks/echo.py" => {:rule, :ping_pong},
    "hooks/state_monitor.py" => {:source, :state_update},
    "hooks/mobile_device.py" => {:source, :phone},
    "hooks/livingroom_button.py" => {:source, :living_room_button},
    "hooks/livingroom_lamps.py" => {:group, :living_room_lamps},
    "hooks/home_doors.py" => {:source, :doors},
    "hooks/klipper_monitor.py" => {:source, :printer_job},
    "hooks/3dprinter_kobra_neo.py" => {:rule, :printer_power},
    "hooks/office_aircond.py" => {:rule, :office_load_shed},
    "hooks/alerts.py" => {:rule, :intruder_latch},
    "hooks/user_location.py" => {:derived, :cal_presence},
    "runners/hapn_tracker.py" => {:derived, :hapn},
    # Ported as a capability, not enabled: the Python declares no weather
    # config, so it has never run and there are no credentials to migrate.
    "runners/weather.py" =>
      {:unconfigured, "no weather entry in the Python config; it has never run"}
  }

  # Structural, not behavioural: base classes and package markers.
  @not_behaviour ["__init__.py", "base.py"]

  setup_all do
    Merlin.Secrets.put(%{
      hapn_auth_endpoint: "x",
      hapn_device_endpoint: "x",
      hapn_client_id: "x",
      hapn_client_secret: "x",
      weather_endpoint: "x",
      weather_api_key: "x",
      discord_webhook: "x"
    })

    {:ok, config} = Merlin.Config.File.load(@config_path)
    {raw, _} = Code.eval_file(@config_path)
    %{config: config, raw: raw}
  end

  defp python_files do
    for dir <- ["hooks", "runners"],
        path = Path.join([@python_root, dir]),
        File.dir?(path),
        file <- File.ls!(path),
        String.ends_with?(file, ".py"),
        file not in @not_behaviour do
      "#{dir}/#{file}"
    end
    |> Enum.sort()
  end

  describe "coverage of the Python implementation" do
    test "the Python source is where this test thinks it is" do
      # Otherwise every assertion below passes over an empty list, and a test
      # that silently checks nothing is worse than no test.
      files = python_files()

      assert files != [],
             "no Python hooks found under #{@python_root}/ -- this test would pass vacuously"

      assert length(files) >= 13
    end

    test "every Python hook and runner is accounted for" do
      for file <- python_files() do
        assert Map.has_key?(@parity, file),
               "#{file} has no recorded parity decision. Port it, or record it as " <>
                 ":deliberately_dropped with a reason -- but decide."
      end
    end

    test "the parity table names no file that no longer exists" do
      files = MapSet.new(python_files())

      for file <- Map.keys(@parity) do
        assert MapSet.member?(files, file),
               "the parity table claims #{file}, which is not in the Python tree any more"
      end
    end

    test "everything the parity table points at exists in the shipped config", %{
      config: config,
      raw: raw
    } do
      for {file, target} <- @parity do
        assert exists?(target, config, raw),
               "#{file} is recorded as becoming #{inspect(target)}, which is not in the " <>
                 "shipped config -- the port was undone, renamed, or never landed"
      end
    end
  end

  defp exists?({:rule, id}, config, _raw),
    do: Enum.any?(config.rules, &(&1.id == id))

  defp exists?({:source, id}, config, _raw),
    do: Enum.any?(config.sources, &(&1.id == id))

  defp exists?({:group, id}, config, _raw),
    do: Map.has_key?(config.groups, id)

  defp exists?({:derived, id}, _config, raw),
    do: Enum.any?(Map.get(raw, :derived, []), &(Map.get(&1, :id) == id))

  defp exists?(:deliberately_dropped, _config, _raw), do: true

  # A recorded decision NOT to configure something is a legitimate answer, and
  # a different one from dropping it: the capability exists and is tested, it
  # simply has nothing to talk to.
  defp exists?({:unconfigured, reason}, _config, _raw) when is_binary(reason), do: true
end
