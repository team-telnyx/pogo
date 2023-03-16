defmodule Pogo.DynamicSupervisor do
  @moduledoc """
  Dynamic Supervisor
  """

  use GenServer, type: :supervisor

  @sync_interval 5_000

  defstruct [:scope, :supervisor, :sync_interval]

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec start_child(Supervisor.child_spec() | {module, term} | module) :: :ok
  def start_child(supervisor \\ __MODULE__, child_spec) do
    case validate_child(child_spec) do
      :ok -> GenServer.call(supervisor, {:start_child, child_spec})
      error -> {:error, error}
    end
  end

  @spec terminate_child(term) :: :ok
  def terminate_child(supervisor \\ __MODULE__, id) do
    GenServer.call(supervisor, {:terminate_child, id})
  end

  @spec which_children(:global | :local) :: [
          {term | :undefined, Supervisor.child() | :restarting, :worker | :supervisor,
           [module] | :dynamic}
        ]
  def which_children(supervisor \\ __MODULE__, scope) do
    GenServer.call(supervisor, {:which_children, scope})
  end

  @impl true
  def init(opts) do
    scope = Keyword.fetch!(opts, :scope)
    sync_interval = Keyword.get(opts, :sync_interval, @sync_interval)

    :pg.start_link(scope)
    :ok = :pg.join(scope, {:member, Node.self()}, self())

    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)

    state = %__MODULE__{
      scope: scope,
      supervisor: supervisor,
      sync_interval: sync_interval
    }

    Process.send_after(self(), :sync, sync_interval)

    {:ok, state}
  end

  @impl true
  def handle_call({:start_child, child_spec}, _from, %{scope: scope} = state) do
    unless self() in :pg.get_members(scope, {:spec, child_spec}) do
      # schedule the child process to be started at next sync
      :pg.join(scope, {:spec, child_spec}, self())
    end

    {:reply, :ok, state}
  end

  def handle_call({:terminate_child, id}, _from, %{scope: scope} = state) do
    with {:ok, child_spec} <- fetch_child_spec(scope, id),
         {:ok, supervisor} <- fetch_supervisor(scope, id) do
      if node(supervisor) == Node.self() do
        # schedule the child process to be terminated at next sync
        :pg.leave(scope, {:spec, child_spec}, self())
      else
        # forward the request to the node that originally scheduled the process
        GenServer.call(supervisor, {:terminate_child, id})
      end
    end

    {:reply, :ok, state}
  end

  def handle_call({:which_children, :local}, _from, %{supervisor: supervisor} = state) do
    {:reply, Supervisor.which_children(supervisor), state}
  end

  def handle_call({:which_children, :global}, _from, %{scope: scope} = state) do
    groups = :pg.which_groups(scope)

    children =
      for {:pid, id} <- groups, reduce: [] do
        acc ->
          case to_child(scope, id) do
            nil -> acc
            child -> [child | acc]
          end
      end

    {:reply, children, state}
  end

  @impl true
  def handle_info(
        :sync,
        %{scope: scope, supervisor: supervisor, sync_interval: sync_interval} = state
      ) do
    distribute_children(scope, supervisor)
    sync_local_children(scope, supervisor)

    Process.send_after(self(), :sync, sync_interval)

    {:noreply, state}
  end

  defp distribute_children(scope, supervisor) do
    self_node = Node.self()
    groups = :pg.which_groups(scope)

    # build a consistent hash ring of existing nodes to distribute
    # child processes among them
    ring =
      for {:member, node} <- groups, reduce: HashRing.new() do
        acc -> HashRing.add_node(acc, node)
      end

    # go through all the child specs and ensure that the current node
    # runs all the proceses designated to it and only them
    for {:spec, %{id: id} = child_spec} <- groups do
      case HashRing.key_to_node(ring, id) do
        ^self_node ->
          # the child process should run on current node

          if self() not in :pg.get_members(scope, {:child, id}) do
            # but it's not running yet, so start it
            {:ok, pid} = Supervisor.start_child(supervisor, child_spec)
            :pg.join(scope, {:child, id}, self())
            :pg.join(scope, {:pid, id}, pid)
          end

        _ ->
          # the child process should run on another node

          if self() in :pg.get_members(scope, {:child, id}) do
            # but it's running on current node, so terminate it here
            with {:ok, pid} <- fetch_local_pid(supervisor, id) do
              Supervisor.terminate_child(supervisor, id)
              Supervisor.delete_child(supervisor, id)
              :pg.leave(scope, {:child, id}, self())
              :pg.leave(scope, {:pid, id}, pid)
            end
          end
      end
    end
  end

  defp sync_local_children(scope, supervisor) do
    # go through all processes supervised by the local supervisor
    # to sync its state with cluster supervisor
    for {id, pid, _, _} <- Supervisor.which_children(supervisor), is_pid(pid) do
      case fetch_child_spec(scope, id) do
        {:ok, _child_spec} ->
          # ensure that we track new pids of child processes that may have
          # crashed and been restarted by local supervisor
          unless pid in :pg.get_members(scope, {:pid, id}) do
            :pg.join(scope, {:pid, id}, pid)
          end

        :error ->
          # terminate child processes that were scheduled to be terminated
          # (by having their specs removed)
          Supervisor.terminate_child(supervisor, id)
          Supervisor.delete_child(supervisor, id)
          :pg.leave(scope, {:child, id}, self())
          :pg.leave(scope, {:pid, id}, pid)
      end
    end
  end

  def to_child(scope, id) do
    with [pid | _] <- :pg.get_members(scope, {:pid, id}),
         {:ok, %{start: {mod, _, _}} = child_spec} <- fetch_child_spec(scope, id) do
      type = Map.get(child_spec, :type, :worker)
      modules = Map.get(child_spec, :modules, [mod])

      {id, pid, type, modules}
    else
      _ -> nil
    end
  end

  def fetch_child_spec(scope, id) do
    groups = :pg.which_groups(scope)

    Enum.find_value(groups, :error, fn
      {:spec, %{id: ^id} = child_spec} ->
        {:ok, child_spec}

      _ ->
        false
    end)
  end

  defp fetch_local_pid(supervisor, id) do
    children = Supervisor.which_children(supervisor)

    Enum.find_value(children, :error, fn
      {^id, pid, _, _} when is_pid(pid) ->
        {:ok, pid}

      _ ->
        false
    end)
  end

  defp fetch_supervisor(scope, id) do
    {:ok, spec} = fetch_child_spec(scope, id)

    case :pg.get_members(scope, {:spec, spec}) do
      [pid | _] -> {:ok, pid}
      _ -> :error
    end
  end

  defp validate_child(%{id: _, start: {mod, _, _} = start} = child) do
    restart = Map.get(child, :restart, :permanent)
    type = Map.get(child, :type, :worker)
    modules = Map.get(child, :modules, [mod])

    shutdown =
      case type do
        :worker -> Map.get(child, :shutdown, 5_000)
        :supervisor -> Map.get(child, :shutdown, :infinity)
      end

    validate_child(start, restart, shutdown, type, modules)
  end

  defp validate_child(other) do
    {:invalid_child_spec, other}
  end

  defp validate_child(start, restart, shutdown, type, modules) do
    with :ok <- validate_start(start),
         :ok <- validate_restart(restart),
         :ok <- validate_shutdown(shutdown),
         :ok <- validate_type(type) do
      validate_modules(modules)
    end
  end

  defp validate_start({m, f, args}) when is_atom(m) and is_atom(f) and is_list(args), do: :ok
  defp validate_start(mfa), do: {:invalid_mfa, mfa}

  defp validate_type(type) when type in [:supervisor, :worker], do: :ok
  defp validate_type(type), do: {:invalid_child_type, type}

  defp validate_restart(restart) when restart in [:permanent, :temporary, :transient], do: :ok
  defp validate_restart(restart), do: {:invalid_restart_type, restart}

  defp validate_shutdown(shutdown) when is_integer(shutdown) and shutdown > 0, do: :ok
  defp validate_shutdown(shutdown) when shutdown in [:infinity, :brutal_kill], do: :ok
  defp validate_shutdown(shutdown), do: {:invalid_shutdown, shutdown}

  defp validate_modules(:dynamic), do: :ok

  defp validate_modules(mods) do
    if is_list(mods) and Enum.all?(mods, &is_atom/1) do
      :ok
    else
      {:invalid_modules, mods}
    end
  end
end
