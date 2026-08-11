defmodule UsbProxy.MixProject do
  use Mix.Project

  @app :usb_proxy
  @version "0.1.0"
  # Only rpi4 is supported: the firmware depends on the custom
  # lawik/nerves_system_rpi4 "usbip" system (USB/IP host + USB tools).
  @all_targets [:rpi4]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      archives: [nerves_bootstrap: "~> 1.15"],
      listeners: listeners(Mix.target(), Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {UsbProxy.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.4.0"},
      {:jason, "~> 1.4"},

      # Web/API layer: one Phoenix endpoint serves JSON API, MCP, and /up
      {:phoenix, "~> 1.8"},
      {:bandit, "~> 1.12"},

      # Ash: every agent-facing operation is an Ash action, exposed via
      # AshJsonApi (JSON API) and ash_ai (MCP tools)
      {:ash, "~> 3.31"},
      {:ash_json_api, "~> 1.7"},
      {:ash_ai, "~> 0.8.2"},

      # Supervised external daemons (tailscaled, usbipd)
      {:muontrap, "~> 1.8"},

      # Serial console service (UART <-> TCP)
      {:circuits_uart, "~> 1.6"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.12"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},

      # Custom system: nerves_system_rpi4 fork with USBIP_CORE/USBIP_HOST,
      # usbip userspace tools, dfu-util, uhubctl, usbutils, eudev.
      # Prebuilt artifact comes from the fork's GitHub releases.
      {:nerves_system_rpi4,
       github: "lawik/nerves_system_rpi4", branch: "usbip", runtime: false, targets: :rpi4}
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://hexdocs.pm/nerves_pack/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  defp listeners(_, _), do: []

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
