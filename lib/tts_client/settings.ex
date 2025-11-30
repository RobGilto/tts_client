defmodule TtsClient.Settings do
  @moduledoc """
  Settings context for managing TTS configuration.
  """

  alias TtsClient.Repo
  alias TtsClient.Settings.Setting

  # Default values
  @defaults %{
    "tts_backend" => "orpheus",
    "orpheus_url" => "http://localhost:8000/tts",
    "orpheus_voice" => "tara",
    "elevenlabs_api_key" => "",
    "elevenlabs_voice_id" => "",
    "elevenlabs_model" => "eleven_turbo_v2_5"
  }

  @doc """
  Gets a setting value by key, returns default if not set.
  """
  def get(key) when is_binary(key) do
    case Repo.get_by(Setting, key: key) do
      nil -> Map.get(@defaults, key)
      setting -> setting.value
    end
  end

  @doc """
  Gets all settings as a map.
  """
  def all do
    settings =
      Setting
      |> Repo.all()
      |> Enum.into(%{}, fn s -> {s.key, s.value} end)

    Map.merge(@defaults, settings)
  end

  @doc """
  Sets a setting value.
  """
  def set(key, value) when is_binary(key) do
    case Repo.get_by(Setting, key: key) do
      nil ->
        %Setting{}
        |> Setting.changeset(%{key: key, value: value})
        |> Repo.insert()

      setting ->
        setting
        |> Setting.changeset(%{value: value})
        |> Repo.update()
    end
  end

  @doc """
  Updates multiple settings at once.
  """
  def update_all(settings_map) when is_map(settings_map) do
    Enum.each(settings_map, fn {key, value} ->
      set(to_string(key), to_string(value))
    end)

    :ok
  end

  @doc """
  Gets the current TTS backend (:orpheus or :elevenlabs)
  """
  def tts_backend do
    case get("tts_backend") do
      "elevenlabs" -> :elevenlabs
      _ -> :orpheus
    end
  end

  @doc """
  Gets Orpheus configuration.
  """
  def orpheus_config do
    %{
      url: get("orpheus_url"),
      voice: get("orpheus_voice")
    }
  end

  @doc """
  Gets ElevenLabs configuration.
  """
  def elevenlabs_config do
    %{
      api_key: get("elevenlabs_api_key"),
      voice_id: get("elevenlabs_voice_id"),
      model: get("elevenlabs_model")
    }
  end

  @doc """
  Checks if ElevenLabs is properly configured.
  """
  def elevenlabs_configured? do
    config = elevenlabs_config()
    config.api_key != "" and config.voice_id != ""
  end
end
