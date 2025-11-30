defmodule TtsClient.TTS.WavStitcher do
  @moduledoc """
  Combines multiple WAV files into a single WAV file.
  Assumes all WAV files have the same format (sample rate, channels, bit depth).
  """

  @doc """
  Stitches multiple WAV binaries into a single WAV binary.
  All WAVs must have compatible formats.
  """
  def stitch(wav_binaries) when is_list(wav_binaries) and length(wav_binaries) > 0 do
    with {:ok, parsed_wavs} <- parse_all_wavs(wav_binaries),
         :ok <- validate_compatible_formats(parsed_wavs),
         {:ok, combined} <- combine_wavs(parsed_wavs) do
      {:ok, combined}
    end
  end

  def stitch([]), do: {:error, :empty_list}
  def stitch(single) when is_binary(single), do: {:ok, single}

  @doc """
  Parses a WAV file and extracts header info and audio data.
  """
  def parse_wav(<<
        "RIFF",
        _file_size::little-32,
        "WAVE",
        rest::binary
      >>) do
    parse_chunks(rest, %{})
  end

  def parse_wav(_), do: {:error, :invalid_wav_header}

  defp parse_chunks(<<"fmt ", chunk_size::little-32, fmt_data::binary-size(chunk_size), rest::binary>>, acc) do
    case parse_fmt_chunk(fmt_data) do
      {:ok, fmt} -> parse_chunks(rest, Map.merge(acc, fmt))
      error -> error
    end
  end

  defp parse_chunks(<<"data", data_size::little-32, audio_data::binary-size(data_size), rest::binary>>, acc) do
    parse_chunks(rest, Map.put(acc, :audio_data, audio_data))
  end

  # Skip unknown chunks
  defp parse_chunks(<<_chunk_id::binary-size(4), chunk_size::little-32, _::binary-size(chunk_size), rest::binary>>, acc) do
    parse_chunks(rest, acc)
  end

  defp parse_chunks(<<>>, acc) do
    if Map.has_key?(acc, :audio_data) and Map.has_key?(acc, :audio_format) do
      {:ok, acc}
    else
      {:error, :incomplete_wav}
    end
  end

  defp parse_chunks(remaining, acc) when byte_size(remaining) < 8 do
    # Trailing bytes or incomplete chunk, ignore if we have data
    if Map.has_key?(acc, :audio_data) and Map.has_key?(acc, :audio_format) do
      {:ok, acc}
    else
      {:error, :incomplete_wav}
    end
  end

  defp parse_fmt_chunk(<<
         audio_format::little-16,
         num_channels::little-16,
         sample_rate::little-32,
         byte_rate::little-32,
         block_align::little-16,
         bits_per_sample::little-16,
         _rest::binary
       >>) do
    {:ok,
     %{
       audio_format: audio_format,
       num_channels: num_channels,
       sample_rate: sample_rate,
       byte_rate: byte_rate,
       block_align: block_align,
       bits_per_sample: bits_per_sample
     }}
  end

  defp parse_fmt_chunk(_), do: {:error, :invalid_fmt_chunk}

  defp parse_all_wavs(wavs) do
    results =
      wavs
      |> Enum.with_index()
      |> Enum.reduce_while([], fn {wav, idx}, acc ->
        case parse_wav(wav) do
          {:ok, parsed} -> {:cont, [parsed | acc]}
          {:error, reason} -> {:halt, {:error, {reason, idx}}}
        end
      end)

    case results do
      {:error, _} = error -> error
      parsed -> {:ok, Enum.reverse(parsed)}
    end
  end

  defp validate_compatible_formats([first | rest]) do
    ref_format = Map.take(first, [:audio_format, :num_channels, :sample_rate, :bits_per_sample])

    incompatible =
      Enum.find_index(rest, fn wav ->
        Map.take(wav, [:audio_format, :num_channels, :sample_rate, :bits_per_sample]) != ref_format
      end)

    case incompatible do
      nil -> :ok
      idx -> {:error, {:incompatible_format, idx + 1}}
    end
  end

  defp combine_wavs([first | _] = parsed_wavs) do
    # Combine all audio data
    combined_audio =
      parsed_wavs
      |> Enum.map(& &1.audio_data)
      |> Enum.join()

    # Build new WAV with combined audio
    wav_binary = build_wav(first, combined_audio)
    {:ok, wav_binary}
  end

  defp build_wav(format, audio_data) do
    data_size = byte_size(audio_data)
    fmt_chunk_size = 16
    # RIFF header (8) + "WAVE" (4) + fmt chunk (8 + 16) + data chunk (8 + data_size)
    file_size = 4 + 8 + fmt_chunk_size + 8 + data_size

    <<
      # RIFF header
      "RIFF",
      file_size::little-32,
      "WAVE",
      # fmt chunk
      "fmt ",
      fmt_chunk_size::little-32,
      format.audio_format::little-16,
      format.num_channels::little-16,
      format.sample_rate::little-32,
      format.byte_rate::little-32,
      format.block_align::little-16,
      format.bits_per_sample::little-16,
      # data chunk
      "data",
      data_size::little-32,
      audio_data::binary
    >>
  end
end
