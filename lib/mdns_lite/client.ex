defmodule MdnsLite.Client do
  @moduledoc """
  Experiment for handling mDNS queries as a client
  """

  use GenServer

  @mdns_group {224, 0, 0, 251}
  @port Application.get_env(:mdns, :port, 5353)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    udp_options = [
      :binary,
      broadcast: true,
      active: true,
      ip: {0, 0, 0, 0},
      ifaddr: {0, 0, 0, 0},
      add_membership: {@mdns_group, {0, 0, 0, 0}},
      multicast_if: {0, 0, 0, 0},
      multicast_loop: true,
      multicast_ttl: 32,
      reuseaddr: true
    ]

    {:ok, udp} = :gen_udp.open(@port, udp_options)
    {:ok, %{udp: udp}}
  end

  def handle_info({:udp, _socket, ip, _port, packet}, state) do
    IO.inspect(ip, label: "IP")
    IO.inspect(DNS.Record.decode(packet), label: "PACKET")
    {:noreply, state}
  end
end
