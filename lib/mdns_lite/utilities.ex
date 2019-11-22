defmodule MdnsLite.Utilities do
  @moduledoc false

  @doc """
  Return a network interface's IP addresses

  * `ifaddrs` - the return value from `:inet.getifaddrs/0`
  """
  @spec ifaddrs_to_ip_list(
          [{ifname :: charlist(), ifopts :: :inet.getifaddrs_ifopts()}],
          ifname :: String.t()
        ) :: [:inet.ip_address()]
  def ifaddrs_to_ip_list(ifaddrs, ifname) do
    ifname_cl = to_charlist(ifname)

    case List.keyfind(ifaddrs, ifname_cl, 0) do
      nil ->
        []

      {^ifname_cl, params} ->
        Keyword.get_values(params, :addr)
    end
  end

  @doc """
  Return whether the IP address is IPv4 (:inet) or IPv6 (:inet6)
  """
  @spec ip_family(:inet.ip_address()) :: :inet | :inet6
  def ip_family({_, _, _, _}), do: :inet
  def ip_family({_, _, _, _, _, _, _, _}), do: :inet6

  @doc """
  Convert a value to an :inet.ip_address()
  """
  @spec to_ip(any) :: :inet.ip_address() | :bad_ip
  def to_ip(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> :bad_ip
      ip_char -> to_ip(ip_char)
    end
  end

  def to_ip(ip) when is_list(ip) do
    case :inet.parse_strict_address(ip) do
      {:ok, ip} -> ip
      _ -> :bad_ip
    end
  end

  def to_ip(ip_str) when is_bitstring(ip_str) do
    to_charlist(ip_str)
    |> to_ip()
  end

  def to_ip(_), do: :bad_ip
end
