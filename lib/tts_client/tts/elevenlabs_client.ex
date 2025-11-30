defmodule TtsClient.TTS.ElevenLabsClient do
  @moduledoc """
  HTTP client for ElevenLabs TTS API.
  https://elevenlabs.io/docs/api-reference/text-to-speech
  """

  require Logger

  @base_url "https://api.elevenlabs.io/v1"
  @timeout 120_000

  @doc """
  Synthesizes text to speech using ElevenLabs API.
  Returns {:ok, audio_binary} or {:error, reason}

  ## Options
    - :api_key - ElevenLabs API key (required)
    - :voice_id - Voice ID to use (required)
    - :model - Model to use (default: "eleven_monolingual_v1")
    - :timeout - Request timeout in ms (default: 120000)
  """
  def synthesize(text, opts \\ []) do
    api_key = Keyword.fetch!(opts, :api_key)
    voice_id = Keyword.fetch!(opts, :voice_id)
    model = Keyword.get(opts, :model, "eleven_monolingual_v1")
    timeout = Keyword.get(opts, :timeout, @timeout)

    url = "#{@base_url}/text-to-speech/#{voice_id}"

    body =
      Jason.encode!(%{
        text: text,
        model_id: model,
        voice_settings: %{
          stability: 0.5,
          similarity_boost: 0.75
        }
      })

    headers = [
      {"Content-Type", "application/json"},
      {"xi-api-key", api_key},
      {"Accept", "audio/mpeg"}
    ]

    case Req.post(url, 
      body: body, 
      headers: headers, 
      receive_timeout: timeout,
      connect_options: [timeout: 30_000]) do
      {:ok, %Req.Response{status: 200, body: audio_data}} ->
        # ElevenLabs returns MP3, convert to WAV for consistency
        convert_mp3_to_wav(audio_data)

      {:ok, %Req.Response{status: 401}} ->
        Logger.error("ElevenLabs API: Invalid API key")
        {:error, :invalid_api_key}

      {:ok, %Req.Response{status: 404, body: body}} ->
        Logger.error("ElevenLabs API: Voice not found - #{inspect(body)}")
        {:error, {:voice_not_found, body}}

      {:ok, %Req.Response{status: 422, body: body}} ->
        Logger.error("ElevenLabs API validation error: #{inspect(body)}")
        {:error, {:validation_error, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("ElevenLabs API error #{status}: #{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.error("ElevenLabs transport error: #{inspect(reason)}")
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        Logger.error("ElevenLabs request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Synthesizes multiple chunks sequentially.
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
  Lists available voices from ElevenLabs.
  """
  def list_voices(api_key) do
    url = "#{@base_url}/voices"

    headers = [
      {"xi-api-key", api_key},
      {"Accept", "application/json"}
    ]

    case Req.get(url, headers: headers) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        voices =
          body
          |> Map.get("voices", [])
          |> Enum.map(fn v -> %{id: v["voice_id"], name: v["name"]} end)

        {:ok, voices}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :invalid_api_key}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Convert MP3 to WAV using ffmpeg
  defp convert_mp3_to_wav(mp3_data) do
    # Write MP3 to temp file
    mp3_path = Path.join(System.tmp_dir!(), "tts_#{:rand.uniform(1_000_000)}.mp3")
    wav_path = Path.join(System.tmp_dir!(), "tts_#{:rand.uniform(1_000_000)}.wav")

    try do
      File.write!(mp3_path, mp3_data)

      # Convert using ffmpeg
      case System.cmd("ffmpeg", [
             "-i", mp3_path,
             "-ar", "24000",
             "-ac", "1",
             "-f", "wav",
             "-y",
             wav_path
           ], stderr_to_stdout: true) do
        {_, 0} ->
          wav_data = File.read!(wav_path)
          {:ok, wav_data}

        {output, code} ->
          Logger.error("ffmpeg conversion failed (#{code}): #{output}")
          {:error, {:ffmpeg_error, code}}
      end
    after
      File.rm(mp3_path)
      File.rm(wav_path)
    end
  end
end
