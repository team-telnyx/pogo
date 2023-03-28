defmodule Pogo.DynamicSupervisorTest do
  use ExUnit.Case
  import AssertAsync

  @supervisor TestApp.DistributedSupervisor

  setup do
    on_exit(fn ->
      # these tests are flaky in CI, sleep below is a naive attempt
      # to give nodes enough time to shutdown after the test
      :timer.sleep(1000)
    end)

    :ok
  end

  test "starts child on a single node in the cluster" do
    [node1, node2] = start_nodes("foo", 2)

    child_spec = Pogo.Worker.child_spec(1)

    start_child(node1, child_spec)
    start_child(node2, child_spec)

    assert_async do
      assert %{
               ^node1 => [],
               ^node2 => [{{Pogo.Worker, 1}, _, :worker, _}]
             } = local_children([node1, node2])
    end
  end

  test "terminates child running in the cluster" do
    [node1, node2] = nodes = start_nodes("foo", 2)

    [child_spec1, _child_spec2, child_spec3] =
      for id <- 1..3 do
        child_spec = Pogo.Worker.child_spec(id)
        start_child(node1, child_spec)
        child_spec
      end

    assert_async do
      assert %{
               ^node1 => [
                 {{Pogo.Worker, 2}, _, :worker, _}
               ],
               ^node2 => [
                 {{Pogo.Worker, 1}, _, :worker, _},
                 {{Pogo.Worker, 3}, _, :worker, _}
               ]
             } = local_children(nodes)
    end

    # terminate using node1 even though the process is running on node2
    terminate_child(node1, child_spec1)

    assert_async do
      assert %{
               ^node1 => [
                 {{Pogo.Worker, 2}, _, :worker, _}
               ],
               ^node2 => [
                 {{Pogo.Worker, 3}, _, :worker, _}
               ]
             } = local_children(nodes)
    end

    # terminate using node2 even though the process was started using node1
    terminate_child(node2, child_spec3)

    assert_async do
      assert %{
               ^node1 => [
                 {{Pogo.Worker, 2}, _, :worker, _}
               ],
               ^node2 => []
             } = local_children(nodes)
    end
  end

  test "keeps track of new pid when child process crashes and gets restarted" do
    [node] = start_nodes("foo", 1)

    child_spec = Pogo.Worker.child_spec(1)
    start_child(node, child_spec)

    :timer.sleep(1000)

    [{{Pogo.Worker, 1}, pid, :worker, _}] = global_children(node)

    # kill child process, it will get restarted by local supervisor
    Process.exit(pid, :brutal_kill)

    assert_async do
      assert [{{Pogo.Worker, 1}, new_pid, :worker, _}] = global_children(node)
      assert new_pid != pid
    end
  end

  test "moves children between nodes when cluster topology changes" do
    [node1] = start_nodes("foo", 1)

    start_child(node1, Pogo.Worker.child_spec(1))
    start_child(node1, Pogo.Worker.child_spec(2))

    assert_async do
      assert %{
               ^node1 => [
                 {{Pogo.Worker, 1}, _, :worker, _},
                 {{Pogo.Worker, 2}, _, :worker, _}
               ]
             } = local_children([node1])
    end

    [node2] = start_nodes("bar", 1)

    assert_async do
      assert %{
               ^node1 => [{{Pogo.Worker, 2}, _, :worker, _}],
               ^node2 => [{{Pogo.Worker, 1}, _, :worker, _}]
             } = local_children([node1, node2])
    end

    stop_nodes([node2])

    assert_async do
      assert %{
               ^node1 => [
                 {{Pogo.Worker, 1}, _, :worker, _},
                 {{Pogo.Worker, 2}, _, :worker, _}
               ]
             } = local_children([node1])
    end
  end

  describe "which_children/1" do
    test "returns children running on the node when called with :local" do
      [node1, node2] = nodes = start_nodes("foo", 2)

      start_child(node1, Pogo.Worker.child_spec(1))
      start_child(node1, Pogo.Worker.child_spec(2))

      assert_async do
        assert [
                 {{Pogo.Worker, 2}, _, :worker, _}
               ] =
                 :rpc.call(node1, Pogo.DynamicSupervisor, :which_children, [@supervisor, :local])
      end

      assert_async do
        assert [
                 {{Pogo.Worker, 1}, _, :worker, _}
               ] =
                 :rpc.call(node2, Pogo.DynamicSupervisor, :which_children, [@supervisor, :local])
      end

      %{
        ^node1 => [{{Pogo.Worker, 2}, pid2, :worker, _}],
        ^node2 => [{{Pogo.Worker, 1}, pid1, :worker, _}]
      } = local_children(nodes)

      assert Pogo.Worker.get_id(pid1) == 1
      assert Pogo.Worker.get_id(pid2) == 2
    end

    test "returns all children running in cluster when called with :global" do
      [node1, node2] = start_nodes("foo", 2)

      start_child(node1, Pogo.Worker.child_spec(1))
      start_child(node1, Pogo.Worker.child_spec(2))

      assert_async do
        assert [
                 {{Pogo.Worker, 1}, _, :worker, _},
                 {{Pogo.Worker, 2}, _, :worker, _}
               ] =
                 :rpc.call(node1, Pogo.DynamicSupervisor, :which_children, [@supervisor, :global])
                 |> Enum.sort()
      end

      assert_async do
        assert [
                 {{Pogo.Worker, 1}, _, :worker, _},
                 {{Pogo.Worker, 2}, _, :worker, _}
               ] =
                 :rpc.call(node2, Pogo.DynamicSupervisor, :which_children, [@supervisor, :global])
                 |> Enum.sort()
      end

      assert global_children(node1) == global_children(node2)

      [
        {{Pogo.Worker, 1}, pid1, :worker, _},
        {{Pogo.Worker, 2}, pid2, :worker, _}
      ] = global_children(node1)

      assert Pogo.Worker.get_id(pid1) == 1
      assert Pogo.Worker.get_id(pid2) == 2
    end
  end

  defp start_nodes(prefix, n) do
    LocalCluster.start_nodes(prefix, n,
      applications: [:test_app],
      files: ["test/support/pogo/worker.ex"]
    )
  end

  defp stop_nodes(nodes) do
    LocalCluster.stop_nodes(nodes)
  end

  defp start_child(node, child_spec) do
    :rpc.call(node, Pogo.DynamicSupervisor, :start_child, [@supervisor, child_spec])
  end

  defp terminate_child(node, %{id: id}) do
    :rpc.call(node, Pogo.DynamicSupervisor, :terminate_child, [@supervisor, id])
  end

  defp local_children(nodes) do
    for node <- nodes, into: %{} do
      local_children =
        :rpc.call(node, Pogo.DynamicSupervisor, :which_children, [@supervisor, :local])

      {node, Enum.sort(local_children)}
    end
  end

  defp global_children(node) do
    :rpc.call(node, Pogo.DynamicSupervisor, :which_children, [@supervisor, :global])
    |> Enum.sort()
  end
end
