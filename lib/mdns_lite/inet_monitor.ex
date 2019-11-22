defmodule MdnsLite.InetMonitor do
  use GenServer

  require Logger

  alias MdnsLite.{Responder, ResponderSupervisor}

  @type ip_record :: {charlist() | String.t(), :inet.ip_address()}

  @scan_interval 10000

  @moduledoc false
  # Watch :inet.getifaddrs/0 for IP address changes and update the active responders.

  defmodule State do
    @moduledoc false

    defstruct [:excluded_ifnames, :ipv4_only, :ip_list]
  end

  @doc """
  Start watching for changes on the specified network interfaces.

  Parameters

    * `:excluded_ifnames` - the list of interface names not to watch
    * `:ipv4_only` - limit notifications to IPv4 addresses
  """
  @spec start_link(excluded_ifnames: [String.t()], ipv4_only: boolean()) :: GenServer.on_start()
  def start_link(init_args) do
    GenServer.start_link(__MODULE__, init_args, name: __MODULE__)
  end

  @doc """
  Add a single or list of ip_record() to the monitor
  """
  @spec add(ip_record | [ip_record]) :: :ok | {:error, :invalid_ip}
  def add(ip) when is_tuple(ip), do: add([ip])
  def add(ip_list), do: GenServer.call(__MODULE__, {:add, ip_list})

  @doc """
  Remove a single or list of ip_record() from the monitor
  """
  @spec remove(ip_record | [ip_record]) :: :ok
  def remove(ip) when is_tuple(ip), do: remove([ip])
  def remove(ip_list), do: GenServer.call(__MODULE__, {:remove, ip_list})

  @impl true
  def init(args) do
    excluded_ifnames = Keyword.get(args, :excluded_ifnames, [])
    excluded_ifnames_cl = Enum.map(excluded_ifnames, &to_charlist/1)

    ipv4_only = Keyword.get(args, :ipv4_only, true)

    state = %State{excluded_ifnames: excluded_ifnames_cl, ip_list: [], ipv4_only: ipv4_only}
    {:ok, state, 1}
  end

  @impl true
  def handle_call({:add, ip_list}, _from, state) do
    validate_ip_list(ip_list)
    |> case do
      :bad_ip ->
        {:reply, {:error, :invalid_ip}, state}

      ip_list ->
        new_ip_list = Enum.uniq(state.ip_list ++ ip_list)
        {:reply, :ok, do_update(state, new_ip_list)}
    end
  end

  def handle_call({:remove, ip_list}, _from, state) do
    new_ip_list =
      Enum.reduce(ip_list, state.ip_list, fn {ifname, addr}, acc ->
        List.delete(acc, {to_charlist(ifname), addr})
      end)

    {:reply, :ok, do_update(state, new_ip_list)}
  end

  @impl true
  def handle_info(:timeout, state) do
    new_state = do_update(state)

    {:noreply, new_state, @scan_interval}
  end

  defp do_update(state, ip_list \\ nil) do
    new_ip_list =
      (ip_list || get_all_ip_addrs())
      |> filter_excluded_ifnames(state.excluded_ifnames)
      |> filter_by_ipv4(state.ipv4_only)

    removed_ips = state.ip_list -- new_ip_list
    added_ips = new_ip_list -- state.ip_list

    Enum.each(removed_ips, fn {_ifname, addr} -> Responder.stop_server(addr) end)
    Enum.each(added_ips, fn {_ifname, addr} -> ResponderSupervisor.start_child(addr) end)

    %State{state | ip_list: new_ip_list}
  end

  defp filter_excluded_ifnames(ip_list, ifnames) do
    Enum.filter(ip_list, fn {ifname, _addr} -> ifname not in ifnames end)
  end

  defp filter_by_ipv4(ip_list, false) do
    ip_list
  end

  defp filter_by_ipv4(ip_list, true) do
    Enum.filter(ip_list, fn {_ifname, addr} -> MdnsLite.Utilities.ip_family(addr) == :inet end)
  end

  defp validate_ip_list(ip_list) do
    Enum.reduce_while(ip_list, [], fn {ifname, addr}, acc ->
      case MdnsLite.Utilities.to_ip(addr) do
        :bad_ip ->
          {:halt, :bad_ip}

        ip ->
          ifname = to_charlist(ifname)
          {:cont, [{ifname, ip} | acc]}
      end
    end)
  end

  defp get_all_ip_addrs() do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs_to_ip_list(ifaddrs)

      _error ->
        []
    end
  end

  defp ifaddrs_to_ip_list(ifaddrs) do
    Enum.flat_map(ifaddrs, &ifaddr_to_ip_list/1)
  end

  defp ifaddr_to_ip_list({ifname, info}) do
    for addr <- Keyword.get_values(info, :addr) do
      {ifname, addr}
    end
  end
end
