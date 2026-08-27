defmodule Merlin.PreflightTest do
  @moduledoc """
  Tier 4: the preflight contract.

  Preflight is the first thing the rc.d script runs and the first acceptance
  check of a cutover, which makes it the one place where "reports success"
  and "verified something" absolutely must be the same thing.

  Six of its nine checks were still skeleton stubs when the deployment survey
  reached them, so `merlin-preflight` exited 0 having examined neither the
  config, nor the secrets, nor the database, nor the broker, nor the ports.
  That is the failure it exists to prevent, in itself.

  So every check here is asserted in BOTH directions: it passes when the thing
  is right, and it is shown to fail when the thing is wrong. A check that
  cannot fail is not a check.
  """

  use ExUnit.Case, async: false

  @moduletag :tier4

  alias Merlin.Preflight

  @good_config ~s|%{
    mqtt: %{host: "127.0.0.1", port: 1883},
    zones: [%{id: :home, center: {42.0, -71.0}, radius: {0.25, :mi}}],
    groups: [%{id: :lamps, members: ["a"], set_topic: "t/set"}],
    sources: [],
    rules: [%{id: :r, desc: "d", on: [{:changes, [:x]}], do: [{:log, :info, "x"}]}]
  }|

  setup do
    dir = Path.join(System.tmp_dir!(), "merlin-preflight-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    saved =
      for v <- ~w(MERLIN_CONFIG MERLIN_SECRETS MERLIN_DB MERLIN_STATE_DIR
                  MERLIN_BROKER_HOST MERLIN_BROKER_PORT MERLIN_PUBLIC_PORT MERLIN_LOCAL_PORT),
          into: %{},
          do: {v, System.get_env(v)}

    on_exit(fn ->
      for {k, v} <- saved do
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end

      File.rm_rf(dir)
    end)

    config = Path.join(dir, "merlin.exs")
    File.write!(config, @good_config)

    System.put_env("MERLIN_CONFIG", config)
    System.put_env("MERLIN_SECRETS", Path.join(dir, "merlin.secrets.exs"))
    System.put_env("MERLIN_STATE_DIR", dir)
    System.put_env("MERLIN_DB", Path.join(dir, "merlin.db"))

    %{dir: dir, config: config}
  end

  defp check(name) do
    Enum.find(Preflight.run(), fn {_status, n, _detail} -> n == name end)
  end

  defp listening(port_fun) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    port_fun.(port)
    {socket, port}
  end

  describe "nothing is reported as pending any more" do
    # The regression, stated directly. Every stub reported "pending", which the
    # report prints and the exit status ignores.
    test "no check is a stub" do
      pending = Enum.filter(Preflight.run(), &match?({:pending, _, _}, &1))

      assert pending == [],
             "these checks still report pending rather than checking: " <>
               inspect(Enum.map(pending, &elem(&1, 1)))
    end

    test "every check merlin claims to make is present" do
      names = Enum.map(Preflight.run(), &elem(&1, 1))

      for expected <- ~w(crypto toolchain state dir secrets config rules database broker listeners),
          expected not in ["dir"] do
        assert Enum.any?(names, &String.starts_with?(&1, expected)),
               "no #{expected} check at all"
      end
    end
  end

  describe "config" do
    test "passes on a config that loads" do
      assert {:ok, "config", _} = check("config")
    end

    test "fails when the file is absent" do
      System.put_env("MERLIN_CONFIG", "/nonexistent/merlin.exs")
      assert {:error, "config", why} = check("config")
      assert why =~ "does not exist"
    end

    test "fails on a config the validator refuses, and says why", %{config: config} do
      File.write!(config, ~s|%{groups: [], sources: [], rules: [], wombat: 1}|)

      assert {:error, "config", why} = check("config")
      assert why =~ "wombat"
    end

    # The specific defect the deployment survey found: a guard naming a zone
    # this house does not have. It loads, it never fires, and nothing says so.
    test "fails on a guard referencing an undeclared zone", %{config: config} do
      File.write!(config, ~s|%{
        zones: [%{id: :home, center: {42.0, -71.0}, radius: {0.25, :mi}}],
        groups: [],
        sources: [],
        rules: [%{id: :r, desc: "d", on: [{:changes, [:x]}], when: "person.cal.zone == :work", do: [{:log, :info, "x"}]}]
      }|)

      assert {:error, "config", why} = check("config")
      assert why =~ ":work"
    end
  end

  describe "rules" do
    test "passes when rules are declared" do
      assert {:ok, "rules", _} = check("rules")
    end

    # main.py:135 fell back to `{}` on a bad config, producing a daemon that
    # started cleanly, connected, loaded no hooks and did nothing -- with
    # everything looking healthy. A rule-less config is that outcome.
    test "fails when the config declares no rules at all", %{config: config} do
      File.write!(config, ~s|%{groups: [], sources: [], rules: []}|)

      assert {:error, "rules", why} = check("rules")
      assert why =~ "do nothing"
    end
  end

  describe "secrets" do
    test "passes when none are needed and none exist" do
      assert {:ok, "secrets", _} = check("secrets")
    end

    test "fails when the file is readable by anyone else", %{dir: dir} do
      file = Path.join(dir, "merlin.secrets.exs")
      File.write!(file, ~s|%{a: "b"}|)
      File.chmod!(file, 0o644)

      assert {:error, "secrets", why} = check("secrets")
      assert why =~ "chmod 600"
    end

    test "fails when the config references a secret that is not defined", %{
      dir: dir,
      config: config
    } do
      File.write!(config, ~s|%{
        groups: [],
        sources: [],
        rules: [],
        derived: [%{id: :p, kind: :http_poll, request: [url: {:secret, :nope}], facts: [%{path: [:a], from: ["a"]}]}]
      }|)

      file = Path.join(dir, "merlin.secrets.exs")
      File.write!(file, ~s|%{}|)
      File.chmod!(file, 0o600)

      assert {:error, "secrets", why} = check("secrets")
      assert why =~ "nope"
    end
  end

  describe "database" do
    test "passes and reports the key count" do
      assert {:ok, "database", detail} = check("database")
      assert detail =~ "key(s)"
    end

    # A path under a directory that does not exist is NOT a failure: KeyStore
    # calls File.mkdir_p and creates it, which is deliberate -- a fresh install
    # should not have to pre-create /var/db/merlin by hand. Worth knowing that
    # this check has that side effect.
    test "creates a missing state directory rather than failing", %{dir: dir} do
      nested = Path.join([dir, "does", "not", "exist", "merlin.db"])
      System.put_env("MERLIN_DB", nested)

      assert {:ok, "database", _} = check("database")
      assert File.exists?(nested)
    end

    test "fails when the path genuinely cannot be opened", %{dir: dir} do
      # A file where a directory must be: mkdir_p cannot fix this, and neither
      # can running as root.
      blocker = Path.join(dir, "blocker")
      File.write!(blocker, "not a directory")
      System.put_env("MERLIN_DB", Path.join(blocker, "merlin.db"))

      assert {:error, "database", _} = check("database")
    end
  end

  describe "broker" do
    test "passes against something that is actually listening" do
      {socket, _port} = listening(fn p -> System.put_env("MERLIN_BROKER_PORT", to_string(p)) end)
      System.put_env("MERLIN_BROKER_HOST", "127.0.0.1")

      assert {:ok, "broker", _} = check("broker")
      :gen_tcp.close(socket)
    end

    # The common case after a broker restart, and indistinguishable from a
    # healthy broker until the first publish.
    test "fails when the host resolves but nothing is listening" do
      System.put_env("MERLIN_BROKER_HOST", "127.0.0.1")
      System.put_env("MERLIN_BROKER_PORT", "1")

      assert {:error, "broker", why} = check("broker")
      assert why =~ "127.0.0.1:1"
    end

    test "fails when the host does not resolve" do
      System.put_env("MERLIN_BROKER_HOST", "no-such-host.invalid")
      System.put_env("MERLIN_BROKER_PORT", "1883")

      assert {:error, "broker", why} = check("broker")
      assert why =~ "does not resolve"
    end
  end

  # The defect the live deployment exposed: preflight loaded the config and
  # never installed it, so every check after it read DEFAULTS. It reported
  # "listeners 8080, 8081" while the config said 1880, and "broker localhost"
  # from a default that happened to match -- validating a different system
  # from the one about to start.
  describe "the config's own values are what get checked" do
    test "the listener check uses the port the config declares", %{config: config} do
      System.delete_env("MERLIN_PUBLIC_PORT")
      System.delete_env("MERLIN_LOCAL_PORT")

      File.write!(config, ~s|%{
        api: %{port: 18877},
        zones: [],
        groups: [],
        sources: [],
        rules: [%{id: :r, desc: "d", on: [{:changes, [:x]}], do: [{:log, :info, "x"}]}]
      }|)

      assert {:ok, "listeners", detail} = check("listeners")

      assert detail =~ "18877",
             "preflight checked a default port instead of the configured one: #{detail}"
    end

    test "the broker check uses the host and port the config declares", %{config: config} do
      System.delete_env("MERLIN_BROKER_HOST")
      System.delete_env("MERLIN_BROKER_PORT")

      File.write!(config, ~s|%{
        mqtt: %{host: "127.0.0.1", port: 1},
        zones: [],
        groups: [],
        sources: [],
        rules: [%{id: :r, desc: "d", on: [{:changes, [:x]}], do: [{:log, :info, "x"}]}]
      }|)

      assert {:error, "broker", why} = check("broker")

      assert why =~ "127.0.0.1:1",
             "preflight checked a default broker instead of the configured one: #{why}"
    end
  end

  describe "listeners" do
    test "passes when the ports are free" do
      for {v, p} <- [{"MERLIN_PUBLIC_PORT", "18999"}, {"MERLIN_LOCAL_PORT", "18998"}] do
        System.put_env(v, p)
      end

      assert {:ok, "listeners", _} = check("listeners")
    end

    # A port another process holds means the daemon starts, loads the config,
    # connects to the broker, and only then fails to listen -- taking the
    # supervision tree with it.
    test "fails when a port is already held" do
      {socket, port} = listening(fn p -> System.put_env("MERLIN_PUBLIC_PORT", to_string(p)) end)
      System.put_env("MERLIN_LOCAL_PORT", "18998")

      assert {:error, "listeners", why} = check("listeners")
      assert why =~ to_string(port)
      :gen_tcp.close(socket)
    end
  end
end
