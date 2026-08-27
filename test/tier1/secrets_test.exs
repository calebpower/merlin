defmodule Merlin.SecretsTest do
  @moduledoc """
  Tier 1: secret references, as pure functions.

  The load-bearing property here is that `referenced/1` and `resolve_deep/1`
  walk the *same* shapes. When they disagreed, the validator confirmed a
  nested secret was defined and the resolver then handed the raw
  `{:secret, name}` tuple to Req -- which raised, restarted the poller, raised
  again, and eventually shut the whole daemon down. Boot validation passed
  the entire way.
  """

  use ExUnit.Case, async: false

  @moduletag :tier1

  alias Merlin.Secrets

  @secrets %{alpha: "A", beta: "B", url: "https://example/x"}

  setup do
    Secrets.put(@secrets)
    on_exit(fn -> Secrets.put(%{}) end)
    :ok
  end

  describe "resolve_deep/1 reaches everywhere referenced/1 does" do
    # The regression, stated directly: a secret nested inside a map value of a
    # keyword list. This is `params: %{"key" => secret}`, which is how every
    # API-key-in-the-query-string vendor is configured.
    test "a secret nested in a map inside a keyword list" do
      term = [url: {:secret, :url}, params: %{"key" => {:secret, :alpha}}]

      assert Secrets.resolve_deep(term) == [
               url: "https://example/x",
               params: %{"key" => "A"}
             ]
    end

    test "a secret in a list of tuples" do
      term = [headers: [{"authorization", {:secret, :beta}}]]
      assert Secrets.resolve_deep(term) == [headers: [{"authorization", "B"}]]
    end

    test "a secret as a map key" do
      assert Secrets.resolve_deep(%{{:secret, :alpha} => 1}) == %{"A" => 1}
    end

    test "a bare reference" do
      assert Secrets.resolve_deep({:secret, :alpha}) == "A"
    end

    test "nested three deep" do
      term = %{a: [b: %{c: [{:secret, :beta}]}]}
      assert Secrets.resolve_deep(term) == %{a: [b: %{c: ["B"]}]}
    end

    # The invariant, rather than a list of shapes I happened to think of: for
    # any term, everything `referenced/1` finds must actually be replaced.
    # A shape one walks and the other does not is precisely the defect.
    test "no reference survives resolution, for every shape referenced/1 finds" do
      terms = [
        [url: {:secret, :url}, params: %{"key" => {:secret, :alpha}}],
        %{a: [b: %{c: [{:secret, :beta}]}]},
        {:secret, :alpha},
        [{:a, {:b, {:secret, :beta}}}],
        %{{:secret, :alpha} => {:secret, :beta}},
        [1, "two", :three, {:secret, :url}],
        %{list: [%{deep: {:secret, :alpha}}]}
      ]

      for term <- terms do
        assert Secrets.referenced(term) != [], "the fixture references nothing: #{inspect(term)}"

        resolved = Secrets.resolve_deep(term)

        assert Secrets.referenced(resolved) == [],
               "resolve_deep left a reference behind in #{inspect(term)} -> #{inspect(resolved)}"
      end
    end

    test "terms with no secrets pass through unchanged" do
      for term <- [[], %{}, "plain", :atom, 42, [a: 1], {1, 2, 3}, %{a: [1, 2]}] do
        assert Secrets.resolve_deep(term) == term
      end
    end

    # Structs are data, not containers to rewrite. Walking one would rebuild
    # it as a plain map and silently strip its __struct__ key.
    test "structs are left alone" do
      uri = URI.parse("https://example/x")
      assert Secrets.resolve_deep(uri) == uri
      assert Secrets.resolve_deep(%{u: uri}) == %{u: uri}
    end

    test "an undefined secret raises rather than passing a tuple onward" do
      assert_raise ArgumentError, ~r/:nope/, fn ->
        Secrets.resolve_deep([params: %{"key" => {:secret, :nope}}])
      end
    end
  end

  describe "load/1 and the permission refusal" do
    setup do
      dir = Path.join(System.tmp_dir!(), "merlin-secrets-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    defp write(dir, contents, mode) do
      file = Path.join(dir, "merlin.secrets.exs")
      File.write!(file, contents)
      File.chmod!(file, mode)
      file
    end

    test "a 0600 file loads", %{dir: dir} do
      file = write(dir, ~s(%{alpha: "A"}), 0o600)
      assert :ok = Secrets.load(file)
      assert Secrets.loaded() == %{alpha: "A"}
    end

    test "0400 also loads -- read-only is stricter, not wrong", %{dir: dir} do
      file = write(dir, ~s(%{alpha: "A"}), 0o400)
      assert :ok = Secrets.load(file)
    end

    for {mode, who} <- [{0o640, "group"}, {0o604, "other"}, {0o644, "both"}, {0o666, "everyone"}] do
      test "#{Integer.to_string(mode, 8)} is refused -- readable by #{who}", %{dir: dir} do
        file = write(dir, ~s(%{alpha: "A"}), unquote(mode))
        assert {:error, {:permissions, ^file, _}} = Secrets.load(file)
      end
    end

    test "a missing file is not an error -- a house with no pollers needs no secrets", %{dir: dir} do
      assert :ok = Secrets.load(Path.join(dir, "absent.exs"))
      assert Secrets.loaded() == %{}
    end

    test "something that is not a map is refused", %{dir: dir} do
      file = write(dir, ~s(["not", "a", "map"]), 0o600)
      assert {:error, {:not_a_map, ^file, :list}} = Secrets.load(file)
    end

    # ORDER, not just outcome. The file is executed to be read, so a check
    # that runs after evaluation has already run whatever was in it. This file
    # raises on evaluation and is also world-readable: the permission error is
    # the only answer that proves the mode was checked first.
    test "the mode is checked BEFORE the file is evaluated", %{dir: dir} do
      file = write(dir, ~s|raise "this file was evaluated"|, 0o644)

      assert {:error, {:permissions, ^file, _}} = Secrets.load(file),
             "the secrets file was evaluated before its permissions were checked"
    end

    test "an eval failure is reported, not raised", %{dir: dir} do
      file = write(dir, ~s|raise "boom"|, 0o600)
      assert {:error, {:eval_failed, ^file, _}} = Secrets.load(file)
    end
  end

  describe "redact/1" do
    test "redacts by value, wherever it is nested" do
      term = [url: "https://example/x", params: %{"key" => "A"}, other: "kept"]

      assert Secrets.redact(term) == [
               url: :redacted,
               params: %{"key" => :redacted},
               other: "kept"
             ]
    end

    test "leaves unresolved references intact -- they are not values" do
      assert Secrets.redact({:secret, :alpha}) == {:secret, :alpha}
    end
  end
end
