defmodule TtsClient.TTS.OrpheusClient do
  @moduledoc """
  HTTP client for the local Orpheus TTS service.

  Supports multi-speaker format: `{voice}: text content`
  Available voices: tara, leah, jess, leo, dan, mia, zac, zoe
  Emotion tags: <laugh>, <chuckle>, <sigh>, <cough>, <sniffle>, <groan>, <yawn>, <gasp>
  """

  require Logger

  @default_url "http://localhost:8000/tts"
  @default_voice "tara"
  @timeout 120_000

  @available_voices ~w(tara leah jess leo dan mia zac zoe)

  @doc """
  Returns the list of available Orpheus voices.
  """
  def available_voices, do: @available_voices

  @doc """
  Synthesizes text to speech and returns the WAV binary.

  If text starts with `{voice_name}:`, that voice will be used automatically.
  Otherwise uses the :voice option or default.

  ## Options
    - :voice - Voice to use (default: "tara", overridden by inline {voice}: format)
    - :url - TTS service URL (default: "http://localhost:8000/tts")
    - :timeout - Request timeout in ms (default: 120000)
  """
  def synthesize(text, opts \\ []) do
    url = Keyword.get(opts, :url, @default_url)
    default_voice = Keyword.get(opts, :voice, @default_voice)
    timeout = Keyword.get(opts, :timeout, @timeout)

    # Parse inline voice from text if present: {voice}: text
    {voice, clean_text} = parse_inline_voice(text, default_voice)

    body = Jason.encode!(%{text: clean_text, voice: voice})

    case Req.post(url,
           body: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: timeout
         ) do
      {:ok, %Req.Response{status: 200, body: wav_data}} ->
        {:ok, wav_data}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("TTS request failed with status #{status}: #{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.error("TTS transport error: #{inspect(reason)}")
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        Logger.error("TTS request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Parses inline voice from text format `{voice}: text content`.
  Returns {voice, clean_text} tuple.
  """
  def parse_inline_voice(text, default_voice) do
    # Match {voice}: at the start of text
    case Regex.run(~r/^\{(\w+)\}:\s*(.*)$/s, String.trim(text)) do
      [_, voice, rest] when voice in @available_voices ->
        {voice, String.trim(rest)}

      _ ->
        {default_voice, text}
    end
  end

  @doc """
  Synthesizes multiple chunks sequentially, returning list of WAV binaries.
  Calls progress_callback after each chunk with {current_index, total, result}.
  """
  def synthesize_chunks(chunks, opts \\ [], progress_callback \\ nil) do
    total = length(chunks)

    results =
      chunks
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {chunk, index}, {:ok, acc} ->
        result = synthesize(chunk, opts)

        if progress_callback do
          progress_callback.({index, total, result})
        end

        case result do
          {:ok, wav} -> {:cont, {:ok, [wav | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case results do
      {:ok, wavs} -> {:ok, Enum.reverse(wavs)}
      error -> error
    end
  end

  @doc """
  Checks if the TTS service is available.
  """
  def health_check(url \\ @default_url) do
    # Try a minimal request to check connectivity
    base_url = url |> URI.parse() |> Map.put(:path, "/") |> URI.to_string()

    case Req.get(base_url, receive_timeout: 5000) do
      {:ok, %Req.Response{status: status}} when status in 200..499 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, {:service_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end
end
