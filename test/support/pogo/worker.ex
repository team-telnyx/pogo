defmodule Pogo.Worker do
  @moduledoc false

  use GenServer

  def child_spec(id) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [id]}
    }
  end

  def start_link(id) do
    GenServer.start_link(__MODULE__, id)
  end

  def get_id(pid) do
    GenServer.call(pid, :id)
  end

  @impl true
  def init(id) do
    {:ok, id}
  end

  @impl true
  def handle_call(:id, _from, id) do
    {:reply, id, id}
  end
end
