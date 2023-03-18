# Pogo

Pogo is a distributed supervisor for clustered Elixir applications.

It uses battle-tested distributed named process groups (`:pg`) under the hood to maintain cluster-wide state and coordinate work between local supervisors running on different nodes.

Features of distributed supevisor:

  * automatically chooses a node to locally supervise child process
  * a child process running in the cluster can be started or stopped using any local supervisor
  * ensures a child is started only once in the cluster (as long as its child spec is unique)
  * redistibutes children when cluster topology changes

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `pogo` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pogo, "~> 0.1.0"}
  ]
end
```

## Example usage

Let's imagine we have an application running on multiple nodes that needs to monitor some external services and we want each of these services to be monitored only once.

Start `Pogo.DynamicSupervisor` under application's supervision tree, locally on each node. All these local supervisors will form a distributed supervisor named `MyApp.DistributedSupervisor`.

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Pogo.DynamicSupervisor, [name: MyApp.DistributedSupervisor, scope: :my_app]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

Now request service monitor processes to be started as children of our distributed supervisor. It can be done on any of the nodes or even on all of them, the distributed supervisor will determine which of the local ones will actually start each child.

```elixir
for service_ip <- ["10.0.0.1", "10.0.0.2", "10.0.0.3"] do
  Pogo.DynamicSupervisor.start_child(
    MyApp.DistributedSupervisor,
    %{
      id: {MyApp.ServiceMonitor, service_ip},
      start: {MyApp.ServiceMonitor, :start_link, [ip: service_ip]}
    }
  )
end
```

We can list locally and globally supervised child processes.

```elixir
Pogo.DynamicSupervisor.which_children(MyApp.DistributedSupervisor, :local)
# [{MyApp.ServiceMonitor, "10.0.0.2"}, #PID<0.2010.0>, :worker, [MyApp.ServiceMonitor]]

Pogo.DynamicSupervisor.which_children(MyApp.DistributedSupervisor, :global)
# [
#   {MyApp.ServiceMonitor, "10.0.0.2"}, #PID<0.2010.0>, :worker, [MyApp.ServiceMonitor],
#   {MyApp.ServiceMonitor, "10.0.0.1"}, #PID<4461.199.10>, :worker, [MyApp.ServiceMonitor],
#   {MyApp.ServiceMonitor, "10.0.0.3"}, #PID<306.320.94>, :worker, [MyApp.ServiceMonitor]
# ]
```

To request a child to be terminated, its id needs to be provided. The request can be made on any of the nodes irrespective of whether the child is supervised locally or not.

```elixir
Pogo.DynamicSupervisor.terminate_child(MyApp.DistributedSupervisor, {MyApp.ServiceMonitor, "10.0.0.3"})
```
