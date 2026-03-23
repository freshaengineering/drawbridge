defmodule DrawbridgeCore.DnsServer do
  @moduledoc """
  Tiny authoritative DNS server for *.dev.local.

  Listens on UDP 192.168.64.1:53 (the host gateway IP on the Apple Container
  NAT network). Containers have resolv.conf pointing here. Any query for
  *.dev.local returns the gateway IP. Everything else gets NXDOMAIN.

  This is needed because:
  - gRPC clients resolve hostnames and send them as :authority headers
  - We need containers to resolve *.dev.local → host gateway IP
  - Apple Container's `system dns create` doesn't actually serve DNS
  """

  use GenServer
  require Logger

  @default_port 53
  @default_ip {192, 168, 64, 1}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)
    ip = Keyword.get(opts, :ip, @default_ip)
    domain = Keyword.get(opts, :domain, "dev.local")
    # The IP to return for all *.dev.local queries
    answer_ip = Keyword.get(opts, :answer_ip, @default_ip)

    case :gen_udp.open(port, [:binary, {:ip, ip}, {:active, true}]) do
      {:ok, socket} ->
        Logger.info("[DnsServer] Listening on #{:inet.ntoa(ip)}:#{port} for *.#{domain}")
        {:ok, %{socket: socket, domain: domain, answer_ip: answer_ip}}

      {:error, :eacces} ->
        Logger.warning(
          "[DnsServer] Cannot bind #{:inet.ntoa(ip)}:#{port} (permission denied). gRPC hostname routing inside containers will not work."
        )

        {:ok, %{socket: nil, domain: domain, answer_ip: answer_ip}}

      {:error, reason} ->
        Logger.warning("[DnsServer] Cannot bind #{:inet.ntoa(ip)}:#{port}: #{inspect(reason)}")
        {:ok, %{socket: nil, domain: domain, answer_ip: answer_ip}}
    end
  end

  def handle_info({:udp, socket, from_ip, from_port, packet}, state) do
    case parse_query(packet) do
      {:ok, id, qname, qtype} ->
        if matches_domain?(qname, state.domain) and qtype in [1, 255] do
          # A record query — respond with the gateway IP
          response = build_response(id, qname, state.answer_ip)
          :gen_udp.send(socket, from_ip, from_port, response)
        else
          # NXDOMAIN for anything else
          response = build_nxdomain(id)
          :gen_udp.send(socket, from_ip, from_port, response)
        end

      :error ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- DNS wire format helpers --

  defp parse_query(
         <<id::16, _flags::16, qdcount::16, _ancount::16, _nscount::16, _arcount::16,
           rest::binary>>
       )
       when qdcount >= 1 do
    case parse_qname(rest) do
      {:ok, qname, <<qtype::16, _qclass::16, _rest::binary>>} ->
        {:ok, id, qname, qtype}

      _ ->
        :error
    end
  end

  defp parse_query(_), do: :error

  defp parse_qname(data), do: parse_qname(data, [])

  defp parse_qname(<<0, rest::binary>>, labels) do
    {:ok, Enum.join(Enum.reverse(labels), "."), rest}
  end

  defp parse_qname(<<len::8, label::binary-size(len), rest::binary>>, labels) when len > 0 do
    parse_qname(rest, [label | labels])
  end

  defp parse_qname(_, _), do: :error

  defp matches_domain?(qname, domain) do
    qname = String.downcase(qname)
    domain = String.downcase(domain)
    qname == domain or String.ends_with?(qname, "." <> domain)
  end

  defp build_response(id, qname, {a, b, c, d}) do
    # Header: ID, flags (QR=1, AA=1, RCODE=0), QDCOUNT=1, ANCOUNT=1
    header = <<id::16, 0x8400::16, 1::16, 1::16, 0::16, 0::16>>
    # Question section (echo back)
    question = encode_qname(qname) <> <<1::16, 1::16>>
    # Answer: name pointer to question, type A, class IN, TTL 60, rdlength 4, IP
    answer = <<0xC00C::16, 1::16, 1::16, 60::32, 4::16, a, b, c, d>>
    header <> question <> answer
  end

  defp build_nxdomain(id) do
    <<id::16, 0x8403::16, 0::16, 0::16, 0::16, 0::16>>
  end

  defp encode_qname(name) do
    name
    |> String.split(".")
    |> Enum.reduce(<<>>, fn label, acc ->
      acc <> <<byte_size(label)::8>> <> label
    end)
    |> Kernel.<>(<<0>>)
  end
end
