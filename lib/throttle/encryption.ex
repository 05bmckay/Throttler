defmodule Throttle.Encryption do
  @moduledoc """
  The Encryption module handles encryption and decryption of sensitive data.
  """

  @aes_block_size 16

  def encrypt(plaintext) do
    iv = :crypto.strong_rand_bytes(@aes_block_size)
    key = encryption_key()
    ciphertext = :crypto.crypto_one_time(:aes_256_cbc, key, iv, pad(plaintext), true)
    Base.encode64(iv <> ciphertext)
  end

  def decrypt(ciphertext) do
    {:ok, decoded} = Base.decode64(ciphertext)
    <<iv::binary-@aes_block_size, ciphertext::binary>> = decoded
    key = encryption_key()
    plaintext = :crypto.crypto_one_time(:aes_256_cbc, key, iv, ciphertext, false)
    unpad(plaintext)
  end

  defp pad(data) do
    pad_length = @aes_block_size - rem(byte_size(data), @aes_block_size)
    data <> :binary.copy(<<pad_length>>, pad_length)
  end

  defp unpad(data) do
    <<pad_length>> = binary_part(data, byte_size(data), -1)
    binary_part(data, 0, byte_size(data) - pad_length)
  end

  defp encryption_key do
    key = Application.get_env(:throttle, :encryption_key) ||
      raise "Encryption key not set. Please set the ENCRYPTION_KEY environment variable."

    # Decode the base64 key
    decoded_key = Base.decode64!(key)

    # Ensure the key is exactly 32 bytes
    case byte_size(decoded_key) do
      32 -> decoded_key
      _ -> :crypto.hash(:sha256, decoded_key)
    end
  end
end
