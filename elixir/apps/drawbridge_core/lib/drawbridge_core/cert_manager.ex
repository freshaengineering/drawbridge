defmodule DrawbridgeCore.CertManager do
  @moduledoc """
  Generates and manages a local CA and wildcard TLS certificates for the proxy.

  On first run, creates a root CA and installs it in the macOS keychain.
  Generates a wildcard cert for *.{domain} signed by the CA.
  """
  require Logger

  @cert_validity_days 825
  @ca_common_name "Drawbridge Local CA"

  @doc "Ensure certs exist for the given domain. Generate if missing."
  def ensure_certs(domain, data_dir) do
    cert_dir = Path.join(Path.expand(data_dir), "certs")
    File.mkdir_p!(cert_dir)

    ca_key_path = Path.join(cert_dir, "ca-key.pem")
    ca_cert_path = Path.join(cert_dir, "ca.pem")
    cert_path = Path.join(cert_dir, "#{domain}.pem")
    key_path = Path.join(cert_dir, "#{domain}-key.pem")

    unless File.exists?(ca_key_path) and File.exists?(ca_cert_path) do
      Logger.info("[CertManager] Generating root CA...")
      generate_ca(ca_key_path, ca_cert_path)
      install_ca_trust(ca_cert_path)
    end

    unless File.exists?(cert_path) and File.exists?(key_path) do
      Logger.info("[CertManager] Generating wildcard cert for *.#{domain}...")
      generate_wildcard_cert(domain, ca_key_path, ca_cert_path, cert_path, key_path)
    end

    {:ok,
     %{
       ca_cert: ca_cert_path,
       cert: cert_path,
       key: key_path
     }}
  end

  @doc "Generate a self-signed root CA key and certificate."
  def generate_ca(key_path, cert_path) do
    # Generate RSA private key
    rsa_key = :public_key.generate_key({:rsa, 4096, 65537})

    # Create self-signed CA certificate
    serial = :crypto.strong_rand_bytes(16) |> :binary.decode_unsigned()

    ca_cert =
      create_self_signed_cert(
        rsa_key,
        @ca_common_name,
        serial,
        _is_ca = true
      )

    # Write PEM files
    write_pem(key_path, :RSAPrivateKey, rsa_key)
    write_pem(cert_path, :Certificate, ca_cert)

    Logger.info("[CertManager] Root CA generated at #{cert_path}")
    :ok
  end

  @doc "Generate a wildcard certificate signed by the CA."
  def generate_wildcard_cert(domain, ca_key_path, ca_cert_path, cert_path, key_path) do
    # Load CA key and cert
    ca_key = read_pem_key(ca_key_path)
    _ca_cert = read_pem_cert(ca_cert_path)

    # Generate new key for the wildcard cert
    cert_key = :public_key.generate_key({:rsa, 2048, 65537})
    serial = :crypto.strong_rand_bytes(16) |> :binary.decode_unsigned()

    wildcard_cert =
      create_signed_cert(
        cert_key,
        ca_key,
        "*.#{domain}",
        serial,
        ["*.#{domain}", domain]
      )

    write_pem(key_path, :RSAPrivateKey, cert_key)
    write_pem(cert_path, :Certificate, wildcard_cert)

    Logger.info("[CertManager] Wildcard cert for *.#{domain} generated at #{cert_path}")
    :ok
  end

  @doc "Install the CA certificate in the macOS system keychain."
  def install_ca_trust(ca_cert_path) do
    Logger.info("[CertManager] Installing CA in macOS keychain (may require sudo)...")

    case System.cmd("security", [
           "add-trusted-cert",
           "-d",
           "-r",
           "trustRoot",
           "-k",
           "/Library/Keychains/System.keychain",
           ca_cert_path
         ]) do
      {_, 0} ->
        Logger.info("[CertManager] CA trusted successfully")
        :ok

      {output, code} ->
        Logger.warning(
          "[CertManager] Failed to install CA trust (exit #{code}): #{output}. " <>
            "You may need to run: sudo security add-trusted-cert -d -r trustRoot " <>
            "-k /Library/Keychains/System.keychain #{ca_cert_path}"
        )

        {:error, :trust_failed}
    end
  end

  # -- Private helpers --

  defp create_self_signed_cert(key, common_name, serial, is_ca) do
    public_key = extract_public_key(key)

    # Use openssl CLI as a reliable fallback for cert generation
    # The Erlang :public_key API for X.509 cert creation is complex
    # and differs across OTP versions
    create_cert_via_openssl(key, public_key, common_name, serial, is_ca, nil, [])
  end

  defp create_signed_cert(cert_key, ca_key, common_name, serial, san_names) do
    public_key = extract_public_key(cert_key)
    create_cert_via_openssl(cert_key, public_key, common_name, serial, false, ca_key, san_names)
  end

  defp create_cert_via_openssl(key, _public_key, common_name, _serial, is_ca, ca_key, san_names) do
    # Write temporary key files and use openssl to generate certs
    # This is more reliable than the Erlang :public_key API for X.509
    tmp_dir = System.tmp_dir!()
    tmp_key = Path.join(tmp_dir, "drawbridge_tmp_#{:rand.uniform(999_999)}.key")
    tmp_cert = Path.join(tmp_dir, "drawbridge_tmp_#{:rand.uniform(999_999)}.crt")
    tmp_conf = Path.join(tmp_dir, "drawbridge_tmp_#{:rand.uniform(999_999)}.cnf")

    try do
      write_pem(tmp_key, :RSAPrivateKey, key)

      if is_ca do
        # Self-signed CA
        conf = """
        [req]
        distinguished_name = req_dn
        x509_extensions = v3_ca
        prompt = no

        [req_dn]
        CN = #{common_name}
        O = Drawbridge

        [v3_ca]
        basicConstraints = critical,CA:TRUE
        keyUsage = critical,keyCertSign,cRLSign
        subjectKeyIdentifier = hash
        """

        File.write!(tmp_conf, conf)

        {_, 0} =
          System.cmd("openssl", [
            "req",
            "-new",
            "-x509",
            "-key",
            tmp_key,
            "-out",
            tmp_cert,
            "-days",
            to_string(@cert_validity_days),
            "-config",
            tmp_conf
          ])
      else
        # Signed by CA
        tmp_ca_key = Path.join(tmp_dir, "drawbridge_ca_#{:rand.uniform(999_999)}.key")
        tmp_csr = Path.join(tmp_dir, "drawbridge_tmp_#{:rand.uniform(999_999)}.csr")

        try do
          write_pem(tmp_ca_key, :RSAPrivateKey, ca_key)

          san_ext =
            san_names
            |> Enum.with_index()
            |> Enum.map(fn {name, i} -> "DNS.#{i + 1} = #{name}" end)
            |> Enum.join("\n")

          conf = """
          [req]
          distinguished_name = req_dn
          req_extensions = v3_req
          prompt = no

          [req_dn]
          CN = #{common_name}
          O = Drawbridge

          [v3_req]
          subjectAltName = @alt_names

          [alt_names]
          #{san_ext}
          """

          File.write!(tmp_conf, conf)

          # Generate CSR
          {_, 0} =
            System.cmd("openssl", [
              "req",
              "-new",
              "-key",
              tmp_key,
              "-out",
              tmp_csr,
              "-config",
              tmp_conf
            ])

          ext_conf_path = Path.join(tmp_dir, "drawbridge_ext_#{:rand.uniform(999_999)}.cnf")

          ext_conf = """
          subjectAltName = @alt_names
          [alt_names]
          #{san_ext}
          """

          File.write!(ext_conf_path, ext_conf)

          # Sign with CA - look up actual CA cert from the standard location
          data_dir = Application.get_env(:drawbridge_core, :data_dir, "~/.drawbridge")
          actual_ca_cert = Path.join([Path.expand(data_dir), "certs", "ca.pem"])

          {_, 0} =
            System.cmd("openssl", [
              "x509",
              "-req",
              "-in",
              tmp_csr,
              "-CA",
              actual_ca_cert,
              "-CAkey",
              tmp_ca_key,
              "-CAcreateserial",
              "-out",
              tmp_cert,
              "-days",
              to_string(@cert_validity_days),
              "-extfile",
              ext_conf_path
            ])

          File.rm(ext_conf_path)
        after
          File.rm(tmp_ca_key)
          File.rm(tmp_csr)
        end
      end

      # Read the generated cert
      {:ok, cert_pem} = File.read(tmp_cert)
      [{:Certificate, cert_der, :not_encrypted}] = :public_key.pem_decode(cert_pem)
      :public_key.pem_entry_decode({:Certificate, cert_der, :not_encrypted})
    after
      File.rm(tmp_key)
      File.rm(tmp_cert)
      File.rm(tmp_conf)
    end
  end

  defp extract_public_key(rsa_private_key) do
    # Extract the public key from RSA private key record
    # RSAPrivateKey record: {_, version, modulus, public_exponent, ...}
    modulus = elem(rsa_private_key, 2)
    public_exponent = elem(rsa_private_key, 3)
    {:RSAPublicKey, modulus, public_exponent}
  end

  defp write_pem(path, type, key) do
    entry = :public_key.pem_entry_encode(type, key)
    pem = :public_key.pem_encode([entry])
    File.write!(path, pem)
    File.chmod!(path, 0o600)
  end

  defp read_pem_key(path) do
    pem = File.read!(path)
    [{:RSAPrivateKey, der, :not_encrypted}] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode({:RSAPrivateKey, der, :not_encrypted})
  end

  defp read_pem_cert(path) do
    pem = File.read!(path)
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode({:Certificate, der, :not_encrypted})
  end
end
