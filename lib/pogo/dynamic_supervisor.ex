defmodule Pogo.DynamicSupervisor do
  @moduledoc """
  Dynamic Supervisor that distributes processes among nodes in the cluster.

  Uses process groups (via `:pg`) under the hood to maintain cluster-wide
  state and coordinate work between supervisor processes running in the
  cluster. Supervisors are organized into independent scopes.

  When a supervisor receives a request to start a child process via
  `start_child/2`, instead of starting it immediately, it propagates that
  request via process groups to supervisors running on other nodes.
  Termination of child processes via `terminate_child/2` works in the same
  way.

  Each supervisor periodically synchronizes its local state by processing
  the start and terminate requests, and updates child process information
  in cluster-wide state.

  Supervisor processes running on different nodes, but operating within the
  same scope, form a hash ring. When processing requests to start child
  processes, supervisors use consistent hashing to determine if they should
  accept the request or not, guaranteeing that there will be exactly one
  supervisor accepting the request and actually starting the child process
  locally.

  Cluster topology changes, with supervisors being added or removed, are
  likely to affect the distribution of child processes - some child processes
  may get rescheduled to supervisors running on different nodes.
  """

  use GenServer, type: :supervisor

  @sync_interval 5_000

  defstruct [:scope, :supervisor, :sync_interval]

  @doc """
  Starts local supervisor and joins cluster-wide scoped process group.

  ## Options

  All options accepted by `Supervisor.init/2` are also accepted here, except for
  `:strategy` which is always `:one_for_one`. Additionally the following options
  can be specified.

    * `scope` - scope to join, supervisors only cooperate with other supervisors
      operating within the same scope
    * `sync_interval` - interval in milliseconds, how often the supervisor should
      synchronize its local state with the cluster by processing requests to
      start and terminate child processes, defaults to `5_000`
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Requests a child process to be started under one of the supervisors in the cluster.
  """
  @spec start_child(Supervisor.supervisor(), Supervisor.child_spec() | {module, term} | module) ::
          :ok | {:error, any}
  def start_child(supervisor, child_spec) do
    child_spec = Supervisor.child_spec(child_spec, [])

    case validate_child(child_spec) do
      :ok -> GenServer.cast(supervisor, {:start_child, child_spec})
      error -> {:error, error}
    end
  end

  @doc """
  Requests a child process running under one of the supervisors in the cluster
  to be terminated.
  """
  @spec terminate_child(Supervisor.supervisor(), term) :: :ok
  def terminate_child(supervisor, id) do
    GenServer.cast(supervisor, {:terminate_child, id})
  end

  @doc """
  Returns a list with information about locally or globally supervised children.
  """
  @spec which_children(Supervisor.supervisor(), :global | :local) :: [
          {term | :undefined, Supervisor.child() | :restarting, :worker | :supervisor,
           [module] | :dynamic}
        ]
  def which_children(supervisor, scope) do
    GenServer.call(supervisor, {:which_children, scope})
  end

  @impl true
  def init(opts) do
    scope = Keyword.fetch!(opts, :scope)
    {sync_interval, opts} = Keyword.pop(opts, :sync_interval, @sync_interval)

    opts = Keyword.put(opts, :strategy, :one_for_one)

    :pg.start_link(scope)
    :ok = :pg.join(scope, {:member, Node.self()}, self())

    {:ok, supervisor} = Supervisor.start_link([], opts)

    state = %__MODULE__{
      scope: scope,
      supervisor: supervisor,
      sync_interval: sync_interval
    }

    Process.send_after(self(), :sync, sync_interval)

    {:ok, state}
  end

  @impl true
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
  def handle_cast({:start_child, child_spec}, %{scope: scope} = state) do
    make_request(scope, {:start_child, child_spec})
    {:noreply, state}
  end

  def handle_cast({:terminate_child, id}, %{scope: scope} = state) do
    make_request(scope, {:terminate_child, id})
    {:noreply, state}
  end

  @impl true
  def handle_info(
        :sync,
        %{scope: scope, supervisor: supervisor, sync_interval: sync_interval} = state
      ) do
    ring = node_ring(scope)

    process_start_child_requests(scope, supervisor, ring)
    process_terminate_child_requests(scope, supervisor, ring)
    distribute_children(scope, supervisor, ring)
    sync_local_children(scope, supervisor)
    sync_specs(scope)
    cleanup(scope)

    Process.send_after(self(), :sync, sync_interval)

    {:noreply, state}
  end

  defp node_ring(scope) do
    groups = :pg.which_groups(scope)

    # build a consistent hash ring of existing nodes to distribute
    # child processes among them
    for {:member, node} <- groups, reduce: HashRing.new() do
      acc -> HashRing.add_node(acc, node)
    end
  end

  defp assign_child(scope, id, ring) do
    assigned_node = HashRing.key_to_node(ring, id)

    assigned_supervisor =
      case :pg.get_members(scope, {:member, assigned_node}) do
        [supervisor | _] -> supervisor
        _ -> nil
      end

    {assigned_node, assigned_supervisor}
  end

  defp process_start_child_requests(scope, supervisor, ring) do
    for {:start_child, %{id: id} = child_spec} = request <- :pg.which_groups(scope) do
      {assigned_node, assigned_supervisor} = assign_child(scope, id, ring)

      cond do
        assigned_node == Node.self() ->
          unless supervising?(scope, child_spec) do
            {:ok, pid} = Supervisor.start_child(supervisor, child_spec)

            track_supervisor(scope, child_spec)
            track_pid(scope, child_spec, pid)
            track_spec(scope, child_spec)
          end

          complete_request(scope, request)

        tracks_spec?(scope, child_spec, assigned_supervisor) ->
          complete_request(scope, request)

        true ->
          :noop
      end
    end
  end

  defp process_terminate_child_requests(scope, supervisor, ring) do
    for {:terminate_child, id} = request <- :pg.which_groups(scope) do
      {assigned_node, assigned_supervisor} = assign_child(scope, id, ring)
      child_spec = get_child_spec(scope, id)

      cond do
        assigned_node == Node.self() ->
          start_terminate(scope, id)

          if child_spec && supervising?(scope, child_spec) do
            Supervisor.terminate_child(supervisor, id)
            Supervisor.delete_child(supervisor, id)

            untrack_supervisor(scope, child_spec)
            untrack_spec(scope, child_spec)
          end

          complete_request(scope, request)

        is_nil(child_spec) || !tracks_spec?(scope, child_spec, assigned_supervisor) ->
          # complete request only after assigned supervisor untracks the spec
          complete_request(scope, request)

        true ->
          :noop
      end
    end
  end

  defp distribute_children(scope, supervisor, ring) do
    self_node = Node.self()

    for {:spec, %{id: id} = child_spec} <- :pg.which_groups(scope) do
      {assigned_node, assigned_supervisor} = assign_child(scope, id, ring)

      case assigned_node do
        ^self_node ->
          # child is assigned to current node
          # start it here, if it's not started yet and it's not being terminated

          unless terminating?(scope, id) || supervising?(scope, child_spec) do
            {:ok, pid} = Supervisor.start_child(supervisor, child_spec)

            track_supervisor(scope, child_spec)
            track_pid(scope, child_spec, pid)
            track_spec(scope, child_spec)
          end

        _ ->
          # child is assigned to a different node
          # terminate it here, but only if it's already started there

          if supervising?(scope, child_spec) &&
               tracks_spec?(scope, child_spec, assigned_supervisor) do
            Supervisor.terminate_child(supervisor, id)
            Supervisor.delete_child(supervisor, id)

            untrack_supervisor(scope, child_spec)
          end
      end
    end
  end

  defp sync_specs(scope) do
    for {:spec, %{id: id} = child_spec} <- :pg.which_groups(scope) do
      cond do
        terminating?(scope, id) ->
          # untrack spec if child is being terminated
          untrack_spec(scope, child_spec)

        alive?(scope, child_spec) ->
          # track spec only after it is started by its assigned supervisor
          track_spec(scope, child_spec)

        true ->
          :noop
      end
    end
  end

  defp sync_local_children(scope, supervisor) do
    # go through all processes supervised by the local supervisor
    # to sync its state with cluster supervisor
    for {id, pid, _, _} <- Supervisor.which_children(supervisor) do
      case pid do
        :undefined ->
          # restart supervised child process that is not running
          with {:ok, pid} when is_pid(pid) <- Supervisor.restart_child(supervisor, id) do
            join_once(scope, {:pid, id}, pid)
          end

        pid when is_pid(pid) ->
          # ensure that we track new pids of child processes that may have
          # crashed and been restarted by local supervisor
          join_once(scope, {:pid, id}, pid)

        _ ->
          :noop
      end
    end
  end

  defp cleanup(scope) do
    # clean up terminating children if they have been untracked by all supervisors
    for {:terminating, id} <- :pg.which_groups(scope),
        :error == fetch_child_spec(scope, id) do
      finish_terminate(scope, id)
    end
  end

  defp make_request(scope, request) do
    join_once(scope, request, self())
  end

  defp complete_request(scope, request) do
    :pg.leave(scope, request, self())
  end

  defp supervising?(scope, %{id: id}) do
    self() in :pg.get_members(scope, {:supervisor, id})
  end

  defp track_supervisor(scope, %{id: id}) do
    :pg.join(scope, {:supervisor, id}, self())
  end

  defp untrack_supervisor(scope, %{id: id}) do
    :pg.leave(scope, {:supervisor, id}, self())
  end

  defp track_pid(scope, %{id: id}, pid) do
    :pg.join(scope, {:pid, id}, pid)
  end

  defp track_spec(scope, child_spec) do
    join_once(scope, {:spec, child_spec}, self())
  end

  defp untrack_spec(scope, child_spec) do
    :pg.leave(scope, {:spec, child_spec}, self())
  end

  defp tracks_spec?(scope, child_spec, supervisor) do
    supervisor in :pg.get_members(scope, {:spec, child_spec})
  end

  defp alive?(scope, child_spec) do
    :pg.get_members(scope, {:pid, child_spec.id}) != []
  end

  defp start_terminate(scope, id) do
    join_once(scope, {:terminating, id}, self())
  end

  defp finish_terminate(scope, id) do
    :pg.leave(scope, {:terminating, id}, self())
  end

  defp terminating?(scope, id) do
    :pg.get_members(scope, {:terminating, id}) != []
  end

  defp join_once(scope, group, pid) do
    unless pid in :pg.get_members(scope, group) do
      :pg.join(scope, group, pid)
    end
  end

  defp to_child(scope, id) do
    with [pid | _] <- :pg.get_members(scope, {:pid, id}),
         {:ok, %{start: {mod, _, _}} = child_spec} <- fetch_child_spec(scope, id) do
      type = Map.get(child_spec, :type, :worker)
      modules = Map.get(child_spec, :modules, [mod])

      {id, pid, type, modules}
    else
      _ -> nil
    end
  end

  defp fetch_child_spec(scope, id) do
    groups = :pg.which_groups(scope)

    Enum.find_value(groups, :error, fn
      {:spec, %{id: ^id} = child_spec} ->
        {:ok, child_spec}

      _ ->
        false
    end)
  end

  defp get_child_spec(scope, id) do
    case fetch_child_spec(scope, id) do
      {:ok, child_spec} -> child_spec
      :error -> nil
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
