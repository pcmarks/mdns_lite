defmodule MdnsLite.Server do
  @moduledoc """
  A GenServer that is responsible for responding to a limited number of mDNS
  requests (queries). A UDP port is opened on the mDNS reserved IP/port. Any
  UDP packets will be caught by handle_info() but only a subset of them are
  of interest.

  For an 'A' type query - address mapping: If the query domain equals this
  server's hostname, respond with an 'A' type resource containing an IP address.

  For a 'PTR' type query - reverse UOP lookup: Given an IP address and it
  matches the server's IP address, respond with the hostname.

  'SRV' service queries.

  Any other query types are ignored.

  There is one of these servers for every network interface managed by
  MdnsLite.
  """

  use GenServer
  require Logger
  alias MdnsLite.Utilities

  # Reserved IANA ip address and port for mDNS
  @mdns_ipv4 {224, 0, 0, 251}
  @mdns_port 5353

  defmodule State do
    @type t() :: struct()
    defstruct ifname: nil,
              query_types: [],
              services: [],
              # Note: Erlang string
              dot_local_name: '',
              ttl: 3600,
              ip: {0, 0, 0, 0},
              udp: nil
  end

  ##############################################################################
  #   Public interface
  ##############################################################################
  @spec start(tuple()) :: GenServer.on_start()
  def start({_ifname, _mdns_config, _mdns_services} = opts) do
    GenServer.start(__MODULE__, opts)
  end

  @doc """
  Leave the mDNS group - close the UDP port. Stop this GenServer.
  """
  @spec stop_server(pid()) :: :ok
  def stop_server(pid) do
    GenServer.call(pid, :leave_mdns_group)
    GenServer.stop(pid)
  end

  # TODO REMOVE ME
  @spec get_state(pid()) :: State.t()
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  ##############################################################################
  #   GenServer callbacks
  ##############################################################################
  @impl true
  def init({ifname, mdns_config, mdns_services}) do
    # We need the IP address for this network interface
    with {:ok, ip_tuple} <- ifname_to_ip(ifname) do
      discovery_name = resolve_mdns_name(mdns_config.host)
      dot_local_name = discovery_name <> "." <> mdns_config.domain
      # Join the mDNS multicast group
      {:ok, udp} = :gen_udp.open(@mdns_port, udp_options(ip_tuple))

      {:ok,
       %State{
         # A list of query types that we'll respond to.
         query_types: mdns_config.query_types,
         # A list of services with types that we'll match against
         services: mdns_services,
         ifname: ifname,
         ip: ip_tuple,
         ttl: mdns_config.ttl,
         udp: udp,
         dot_local_name: to_charlist(dot_local_name)
       }}
    else
      {:error, reason} ->
        Logger.error("reason: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  @doc """
  Leave the mDNS UDP group.
  """
  def handle_call(:leave_mdns_group, _from, state) do
    if state.udp do
      :gen_udp.close(state.udp)
    end

    {:reply, :ok, %State{state | udp: nil}}
  end

  @doc """
  This handle_info() captures mDNS UDP multicast packets. Some client/service has
  written to the mDNS multicast port. We are only interested in queries and of
  those queries those that are germane.
  """
  @impl true
  def handle_info({:udp, _socket, _ip, _port, packet}, state) do
    # Decode the UDP packet
    dns_record = DNS.Record.decode(packet)
    # qr is the query/response flag; false (0) = query, true (1) = response
    if !dns_record.header.qr && length(dns_record.qdlist) > 0 do
      {:noreply, prepare_response(dns_record, state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ##############################################################################
  #   Private functions
  ##############################################################################
  # A standard mDNS response packet
  defp response_packet(id, query_list, answer_list),
    do: %DNS.Record{
      header: %DNS.Header{
        id: id,
        aa: true,
        qr: true,
        opcode: 0,
        rcode: 0
      },
      # The orginal queries
      qdlist: query_list,
      # A list of answer entries. Can be empty.
      anlist: answer_list,
      # A list of resource entries. Can be empty.
      arlist: []
    }

  defp prepare_response(dns_record, state) do
    # There can be multiple questions in a query. And it must be one of the
    # query types specified in the configuration
    dns_record.qdlist
    |> Enum.filter(fn q -> q.type in state.query_types end)
    |> Enum.each(fn %DNS.Query{} = query ->
      handle_query(query, dns_record, state)
    end)

    state
  end

  # An "A" type query. Address mapping record. Return the IP address if
  # this host name matches the query domain.
  defp handle_query(%DNS.Query{class: :in, type: :a, domain: domain} = _query, dns_record, state) do
    Logger.debug("DNS A RECORD for ifname #{inspect(state.ifname)}\n#{inspect(dns_record)}")

    case state.dot_local_name == domain do
      true ->
        resource_record = %DNS.Resource{
          class: :in,
          type: :a,
          ttl: state.ttl,
          domain: state.dot_local_name,
          data: state.ip
        }

        send_response([resource_record], dns_record, state)

      _ ->
        nil
    end
  end

  # A "PTR" type query. Reverse address lookup. Return the hostname of an
  # IP address
  defp handle_query(
         %DNS.Query{class: :in, type: :ptr, domain: domain} = _query,
         dns_record,
         state
       ) do
    Logger.debug("DNS PTR RECORD for ifname #{inspect(state.ifname)}\n#{inspect(dns_record)}")
    # Convert our IP address so as to be able to match the arpa address
    # in the query. Arpa address for IP 192.168.0.112 is 112.0.168.192,in-addr.arpa
    arpa_address =
      state.ip
      |> Tuple.to_list()
      |> Enum.reverse()
      |> Enum.join(".")

    # Only need to match the beginning characters
    if String.starts_with?(to_string(domain), arpa_address) do
      resource_record = %DNS.Resource{
        class: :in,
        type: :ptr,
        ttl: state.ttl,
        data: state.dot_local_name
      }

      send_response([resource_record], dns_record, state)
    end
  end

  # A "SRV" type query. Find services, e.g., HTTP, SSH. The domain field in a
  # SRV service query will look like "_http._tcp.local". Respond only on an exact
  # match
  defp handle_query(
         %DNS.Query{class: :in, type: :srv, domain: domain} = _query,
         dns_record,
         state
       ) do
    Logger.debug("DNS SRV RECORD for ifname #{inspect(state.ifname)}\n#{inspect(dns_record)}")

    state.services
    |> Enum.filter(fn service ->
      local_service = service.type <> ".local"
      to_string(domain) == local_service
    end)
    |> Enum.each(fn service ->
      # construct the data value to be returned
      # Note: The spec - RFC 2782 - specifies that the target/hostname end with a dot.
      target = state.dot_local_name ++ '.'
      data = {service.priority, service.weight, service.port, target}

      resource_record = %DNS.Resource{
        class: :in,
        type: :srv,
        ttl: state.ttl,
        data: data
      }

      send_response([resource_record], dns_record, state)
    end)
  end

  # Ignore any other type of query
  defp handle_query(%DNS.Query{type: type} = _query, dns_record, state) do
    Logger.debug(
      "IGNORING #{inspect(type)} DNS RECORD for ifname #{inspect(state.ifname)}\n#{
        inspect(dns_record)
      }"
    )
  end

  defp send_response(dns_resource_records, dns_record, state) do
    # Construct a DNS record from the query plus answwers (resource records)
    packet = response_packet(dns_record.header.id, dns_record.qdlist, dns_resource_records)
    Logger.debug("Sending DNS response packet\n#{inspect(packet)}")
    dns_record = DNS.Record.encode(packet)
    :gen_udp.send(state.udp, @mdns_ipv4, @mdns_port, dns_record)
  end

  defp ifname_to_ip(ifname) do
    with {:ok, ifaddrs} <- :inet.getifaddrs(),
         addr when addr != nil <- find_ipv4_addr(ifaddrs, ifname) do
      {:ok, addr}
    else
      _ ->
        {:error, :no_ip_address}
    end
  end

  defp find_ipv4_addr(ifaddrs, ifname) do
    ifaddrs
    |> Utilities.ifaddrs_to_ip_list(ifname)
    |> Enum.find(&(Utilities.ip_family(&1) == :inet))
  end

  defp resolve_mdns_name(nil), do: nil

  defp resolve_mdns_name(:hostname) do
    {:ok, hostname} = :inet.gethostname()
    hostname |> to_string
  end

  defp resolve_mdns_name(mdns_name), do: mdns_name

  defp udp_options(ip) do
    [
      :binary,
      active: true,
      # add_membership: {@mdns_ipv4, {0, 0, 0, 0}},
      add_membership: {@mdns_ipv4, ip},
      multicast_if: ip,
      multicast_loop: true,
      multicast_ttl: 255,
      reuseaddr: true
    ]
  end
end
