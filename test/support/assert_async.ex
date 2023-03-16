defmodule AssertAsync do
  @moduledoc """
  Helper macro for making assertions on async actions. This is particularly
  useful for testing GenServers and other processes that may be synchronously
  processing messages. The macro will retry an assertion until it passes
  or times out.

  ## Example

      defmodule Foo do
        use GenServer

        def init(opts) do
          {:ok, state, {:continue, :sleep}}
        end

        def handle_continue(:sleep, state) do
          Process.sleep(2_000)
          {:noreply, state}
        end

        def handle_call(:bar, _, state) do
          Map.get(state, :bar)
        end
      end

      iex> import AssertAsync
      iex {:ok, pid} = GenServer.start_link(Foo, %{bar: 42})
      iex> assert_async do
      ...>   assert GenServer.call(pid, :bar) == 42
      ...> end

  ## Configuration

  * `sleep` - Time in milliseconds to wait before next retry. Defaults to `200`.
  * `max_tries` - Number of attempts to make before flunking assertion. Defaults to `10`.
  * `debug` - Boolean for producing `DEBUG` messages on failing iterations. Defaults `false`.
  """

  defmodule Impl do
    @moduledoc false
    require Logger

    @defaults %{
      sleep: 200,
      max_tries: 10,
      debug: false
    }

    def assert(function, opts) do
      state = Map.merge(@defaults, Map.new(opts))
      do_assert(function, state)
    end

    defp do_assert(function, %{max_tries: 1}) do
      function.()
    end

    defp do_assert(function, %{max_tries: max_tries} = opts) do
      function.()
    rescue
      e in ExUnit.AssertionError ->
        if opts.debug do
          Logger.debug(fn ->
            "AssertAsync(remaining #{max_tries - 1}): #{ExUnit.AssertionError.message(e)}"
          end)
        end

        Process.sleep(opts.sleep)
        do_assert(function, %{opts | max_tries: max_tries - 1})
    end
  end

  defmacro assert_async(opts \\ [], do: do_block) do
    quote do
      AssertAsync.Impl.assert(fn -> unquote(do_block) end, unquote(opts))
    end
  end
end
