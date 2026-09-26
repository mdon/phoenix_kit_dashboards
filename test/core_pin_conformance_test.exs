defmodule PhoenixKitDashboards.CorePinConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the `:phoenix_kit` requirement against being re-narrowed to a single
  core MINOR, against a floor that is lower than the API this module calls,
  and against a local path override reaching a commit.

  The trap is the three-segment form: `~> 2.15.x` expands to
  `>= 2.15.x and < 2.16.0`, so no 2.16 or later core satisfies it. The
  breakage lands on CONSUMERS, never here — a host depending on both this
  module and a newer core minor gets an unsolvable dependency set and
  `mix deps.get` fails outright, with no degraded mode. Nothing else in this
  repo's own test run would notice, which is why the check is a test rather
  than a convention.

  The floor is **2.15.0**, and it is a real floor rather than a rounded guess:
  `Placements.write/3` calls `Settings.update_setting_with_module/4`, whose
  arity-4 form first shipped in core 2.15.0. Below it that call raises
  `UndefinedFunctionError`, which `write/3` rescues into a generic message —
  so on an older 2.x every place/unplace/reprioritise fails SILENTLY. That is
  why 2.0.0 is now in `@must_reject`: this list said the module worked there,
  and it did not.

  Core 1.7 is deliberately excluded: core 2.0.0 squashed the migration chain to
  a V135 floor and this module is verified only against that baseline.

  ## Raising the floor again

  Whenever this module starts calling a core function newer than 2.38.0, move
  BOTH the `mix.exs` requirement and `@floor` here, and add the version below
  it to `@must_reject`. A floor that lags the API is invisible to every other
  gate in the repo, because the suite runs against local core.

  The floor is `>= 2.38.0 and < 3.0.0` now: the actor and the activity log
  come from `PhoenixKitWeb.Actor` and `Activity.log/3`, first shipped in core
  2.38.0 and no longer feature-detected — an older core does not compile the
  package. Any earlier floor's reasons above still hold below it. Keep the
  compound form: patch-precise at the bottom, open through every later 2.x
  minor at the top.
  """

  @floor "2.38.0"
  @must_admit ["2.38.0", "2.38.1", "2.39.0", "2.99.4"]
  @must_reject ["1.7.236", "2.0.0", "2.15.0", "2.15.4", "2.16.0", "2.22.16", "2.37.5", "3.0.0"]

  test "the :phoenix_kit requirement admits every core >= 2.38.0 minor and nothing else" do
    requirement = core_requirement()

    assert match?({:ok, _parsed}, Version.parse_requirement(requirement)),
           "`:phoenix_kit` requirement #{inspect(requirement)} is not a valid requirement"

    for version <- @must_admit do
      assert Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} rejects core #{version}. " <>
               "A pin that excludes a core minor at or above the floor breaks " <>
               "`mix deps.get` for every host running this module alongside that " <>
               "core. Keep the floor patch-precise and the ceiling open (`>= 2.38.0 and < 3.0.0`)."
    end

    for version <- @must_reject do
      refute Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} admits core #{version}, " <>
               "which is outside the range this module is verified against."
    end
  end

  test "the floor admits its own version and rejects the release below it" do
    requirement = core_requirement()

    assert Version.match?(@floor, requirement),
           "the requirement must admit the floor #{@floor} itself"

    refute Version.match?("2.37.5", requirement),
           "core 2.14.9 lacks `Settings.update_setting_with_module/4`, which " <>
             "`Placements.write/3` calls — every placement write would fail silently"
  end

  # Resolution order matters. `Mix.Project.config()` is exact, but it reports the
  # dep as it resolved THIS run — and `pk_dep/3` rewrites it to a `path:` tuple
  # whenever PHOENIX_KIT_PATH is exported, which is the workspace's sanctioned way
  # to run this suite against unreleased core. Reading the committed literal from
  # mix.exs as a fallback keeps the check meaningful under that override instead
  # of failing the documented workflow — and it still fails when a path dep is
  # COMMITTED, because then there is no literal left to find.
  defp core_requirement do
    resolved_requirement() || committed_requirement() ||
      flunk("""
      No version requirement found for `:phoenix_kit`.

      Neither the resolved dep nor mix.exs carries one, which means a `path:`
      dep has been committed. That ships a broken package and breaks every
      other consumer's build — restore the published requirement.
      """)
  end

  defp resolved_requirement do
    Mix.Project.config()
    |> Keyword.get(:deps, [])
    |> Enum.find_value(fn
      {:phoenix_kit, requirement} when is_binary(requirement) -> requirement
      {:phoenix_kit, requirement, _opts} when is_binary(requirement) -> requirement
      _ -> nil
    end)
  end

  # First match wins, matching how every other tool in the workspace reads this
  # pin. Covers both the bare `{:phoenix_kit, "..."}` and the `pk_dep(:phoenix_kit,
  # "...")` forms, since the captured text is identical in each.
  defp committed_requirement do
    case Regex.run(~r/:phoenix_kit,\s*"([^"]+)"/, File.read!("mix.exs")) do
      [_full, requirement] -> requirement
      _ -> nil
    end
  end
end
