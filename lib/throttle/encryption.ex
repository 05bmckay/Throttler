defmodule Throttle.Encryption do
  @moduledoc """
  Handles encryption and decryption of sensitive data using AES-256-GCM.

  New encryptions use AES-256-GCM (version 2). Legacy AES-256-CBC ciphertext
  (version 1, no prefix byte) is still supported for decryption only.

  Ciphertext format (v2): Base64(<<2>> <> iv_12 <> tag_16 <> ciphertext)
  Ciphertext format (v1): Base64(iv_16 <> ciphertext)  [legacy CBC, no prefix]
  """

  require Logger

  @gcm_iv_size 12
  @gcm_tag_size 16
  @cbc_block_size 16
  @version_gcm 2

  def encrypt(plaintext) do
    key = encryption_key()
    iv = :crypto.strong_rand_bytes(@gcm_iv_size)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", true)
    Base.encode64(<<@version_gcm>> <> iv <> tag <> ciphertext)
  end

  def decrypt(ciphertext) do
    try do
      {:ok, decoded} = Base.decode64(ciphertext)
      key = encryption_key()

      case decoded do
        <<@version_gcm, iv::binary-@gcm_iv_size, tag::binary-@gcm_tag_size, ct::binary>> ->
          decrypt_gcm(key, iv, tag, ct)

        <<_iv_start::binary-@cbc_block_size, _rest::binary>> ->
          decrypt_legacy_cbc(key, decoded)
      end
    rescue
      e ->
        Logger.error("Decryption failed: #{inspect(e)}")
        Logger.error("Ciphertext: #{inspect(ciphertext)}")
        {:error, :decryption_failed}
    catch
      :error, :function_clause ->
        Logger.error("Decryption failed: Invalid padding")
        Logger.error("Ciphertext: #{inspect(ciphertext)}")
        {:error, :invalid_padding}
    end
  end

  defp decrypt_gcm(key, iv, tag, ciphertext) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false) do
      :error -> {:error, :decryption_failed}
      plaintext -> {:ok, plaintext}
    end
  end

  defp decrypt_legacy_cbc(key, decoded) do
    <<iv::binary-@cbc_block_size, ciphertext::binary>> = decoded
    plaintext = :crypto.crypto_one_time(:aes_256_cbc, key, iv, ciphertext, false)
    {:ok, unpad(plaintext)}
  end

  defp unpad(data) do
    <<pad_length>> = binary_part(data, byte_size(data), -1)
    binary_part(data, 0, byte_size(data) - pad_length)
  end

  defp encryption_key do
    key =
      Application.get_env(:throttle, :encryption_key) ||
        raise "Encryption key not set. Please set the ENCRYPTION_KEY environment variable."

    decoded_key = Base.decode64!(key)

    case byte_size(decoded_key) do
      32 ->
        decoded_key

      n ->
        raise "ENCRYPTION_KEY must decode to exactly 32 bytes (got #{n}). " <>
                "Generate one with: :crypto.strong_rand_bytes(32) |> Base.encode64()"
    end
  end
end
