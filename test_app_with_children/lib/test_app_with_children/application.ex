defmodule TestAppWithChildren.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Pogo.DynamicSupervisor,
       name: PogoTest.DistributedSupervisor,
       scope: :test,
       sync_interval: 100,
       children: [
         Pogo.Worker.child_spec(1),
         Pogo.Worker.child_spec(2),
         Pogo.Worker.child_spec(3)
       ]}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TestAppWithChildren.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
