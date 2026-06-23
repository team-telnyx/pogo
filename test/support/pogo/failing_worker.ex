defmodule Pogo.FailingWorker do
  @moduledoc false

  # Test worker whose init fails on demand. Used to verify that a child failing
  # to start does not crash the Pogo.DynamicSupervisor and take every other
  # child down with it.

  use GenServer

  def child_spec(id) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [id]},
      restart: :temporary
    }
  end

  def start_link(id) do
    GenServer.start_link(__MODULE__, id)
  end

  @impl true
  def init(_id) do
    {:stop, :always_fails}
  end
end
