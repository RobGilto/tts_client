defmodule TtsClient.TTS.Client do
  @moduledoc """
  Unified TTS client that dispatches to the appropriate backend (Orpheus or ElevenLabs).
  """

  alias TtsClient.Settings
  alias TtsClient.TTS.{OrpheusClient, ElevenLabsClient}

  @doc """
  Synthesizes text to speech using the configured backend.
  Returns {:ok, wav_binary} or {:error, reason}

  ## Options
    - :backend - Override backend (:orpheus or :elevenlabs)
    - Backend-specific options are passed through
  """
  def synthesize(text, opts \\ []) do
    backend = Keyword.get(opts, :backend, Settings.tts_backend())

    case backend do
      :orpheus -> synthesize_orpheus(text, opts)
      :elevenlabs -> synthesize_elevenlabs(text, opts)
    end
  end

  @doc """
  Synthesizes multiple chunks sequentially using the configured backend.
  """
  def synthesize_chunks(chunks, opts \\ [], progress_callback \\ nil) do
    backend = Keyword.get(opts, :backend, Settings.tts_backend())

    case backend do
      :orpheus -> OrpheusClient.synthesize_chunks(chunks, orpheus_opts(opts), progress_callback)
      :elevenlabs -> ElevenLabsClient.synthesize_chunks(chunks, elevenlabs_opts(opts), progress_callback)
    end
  end

  defp synthesize_orpheus(text, opts) do
    OrpheusClient.synthesize(text, orpheus_opts(opts))
  end

  defp synthesize_elevenlabs(text, opts) do
    ElevenLabsClient.synthesize(text, elevenlabs_opts(opts))
  end

  defp orpheus_opts(opts) do
    config = Settings.orpheus_config()

    opts
    |> Keyword.put_new(:url, config.url)
    |> Keyword.put_new(:voice, config.voice)
  end

  defp elevenlabs_opts(opts) do
    config = Settings.elevenlabs_config()

    opts
    |> Keyword.put_new(:api_key, config.api_key)
    |> Keyword.put_new(:voice_id, config.voice_id)
    |> Keyword.put_new(:model, config.model)
  end
end
