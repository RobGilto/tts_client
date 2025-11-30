defmodule TtsClientWeb.SettingsLive do
  use TtsClientWeb, :live_view

  alias TtsClient.Settings

  @impl true
  def mount(_params, _session, socket) do
    settings = Settings.all()

    {:ok,
     assign(socket,
       settings: settings,
       saved: false,
       error: nil,
       testing_orpheus: false,
       testing_elevenlabs: false,
       orpheus_status: nil,
       elevenlabs_status: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto p-6">
      <div class="flex justify-between items-center mb-6">
        <h1 class="text-3xl font-bold">TTS Settings</h1>
        <a href={~p"/tts/stream"} class="text-blue-600 hover:underline">
          Back to TTS
        </a>
      </div>

      <%= if @saved do %>
        <div class="mb-4 p-3 bg-green-100 border border-green-300 rounded-lg text-green-700">
          Settings saved successfully!
        </div>
      <% end %>

      <%= if @error do %>
        <div class="mb-4 p-3 bg-red-100 border border-red-300 rounded-lg text-red-700">
          Error: <%= @error %>
        </div>
      <% end %>

      <form phx-submit="save" phx-change="validate" class="space-y-8">
        <!-- Orpheus Settings -->
        <div class="bg-white p-6 rounded-lg shadow border">
          <h2 class="text-xl font-semibold mb-4 flex items-center gap-2">
            <span class="w-3 h-3 rounded-full bg-green-500"></span>
            Local Orpheus TTS
          </h2>

          <div class="space-y-4">
            <div>
              <label for="orpheus_url" class="block text-sm font-medium text-gray-700 mb-1">
                Server URL
              </label>
              <input
                type="text"
                id="orpheus_url"
                name="orpheus_url"
                value={@settings["orpheus_url"]}
                placeholder="http://localhost:8000/tts"
                class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500"
              />
              <p class="mt-1 text-xs text-gray-500">Default: http://localhost:8000/tts</p>
            </div>

            <div>
              <label for="orpheus_voice" class="block text-sm font-medium text-gray-700 mb-1">
                Default Voice
              </label>
              <input
                type="text"
                id="orpheus_voice"
                name="orpheus_voice"
                value={@settings["orpheus_voice"]}
                placeholder="tara"
                class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500"
              />
            </div>

            <div class="flex items-center gap-3">
              <button
                type="button"
                phx-click="test_orpheus"
                disabled={@testing_orpheus}
                class="px-4 py-2 bg-gray-100 text-gray-700 rounded-lg hover:bg-gray-200 disabled:opacity-50"
              >
                <%= if @testing_orpheus, do: "Testing...", else: "Test Connection" %>
              </button>
              <%= if @orpheus_status do %>
                <span class={status_class(@orpheus_status)}>
                  <%= status_text(@orpheus_status) %>
                </span>
              <% end %>
            </div>
          </div>
        </div>

        <!-- ElevenLabs Settings -->
        <div class="bg-white p-6 rounded-lg shadow border">
          <h2 class="text-xl font-semibold mb-4 flex items-center gap-2">
            <span class="w-3 h-3 rounded-full bg-purple-500"></span>
            ElevenLabs TTS
          </h2>

          <div class="space-y-4">
            <div>
              <label for="elevenlabs_api_key" class="block text-sm font-medium text-gray-700 mb-1">
                API Key
              </label>
              <input
                type="password"
                id="elevenlabs_api_key"
                name="elevenlabs_api_key"
                value={@settings["elevenlabs_api_key"]}
                placeholder="Enter your ElevenLabs API key"
                class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500"
              />
              <p class="mt-1 text-xs text-gray-500">
                Get your API key from <a href="https://elevenlabs.io" target="_blank" class="text-blue-600 hover:underline">elevenlabs.io</a>
              </p>
            </div>

            <div>
              <label for="elevenlabs_voice_id" class="block text-sm font-medium text-gray-700 mb-1">
                Voice ID
              </label>
              <input
                type="text"
                id="elevenlabs_voice_id"
                name="elevenlabs_voice_id"
                value={@settings["elevenlabs_voice_id"]}
                placeholder="e.g., 21m00Tcm4TlvDq8ikWAM"
                class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500"
              />
              <p class="mt-1 text-xs text-gray-500">
                Find voice IDs in your ElevenLabs dashboard
              </p>
            </div>

            <div>
              <label for="elevenlabs_model" class="block text-sm font-medium text-gray-700 mb-1">
                Model
              </label>
              <select
                id="elevenlabs_model"
                name="elevenlabs_model"
                class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500"
              >
                <option value="eleven_turbo_v2_5" selected={@settings["elevenlabs_model"] == "eleven_turbo_v2_5"}>
                  Eleven Turbo v2.5 (Fastest, cheapest)
                </option>
                <option value="eleven_flash_v2_5" selected={@settings["elevenlabs_model"] == "eleven_flash_v2_5"}>
                  Eleven Flash v2.5 (Fast, low cost)
                </option>
                <option value="eleven_multilingual_v2" selected={@settings["elevenlabs_model"] == "eleven_multilingual_v2"}>
                  Eleven Multilingual v2 (Best quality)
                </option>
                <option value="eleven_monolingual_v1" selected={@settings["elevenlabs_model"] == "eleven_monolingual_v1"}>
                  Eleven Monolingual v1 (Legacy)
                </option>
              </select>
            </div>

            <div class="flex items-center gap-3">
              <button
                type="button"
                phx-click="test_elevenlabs"
                disabled={@testing_elevenlabs or @settings["elevenlabs_api_key"] == ""}
                class="px-4 py-2 bg-gray-100 text-gray-700 rounded-lg hover:bg-gray-200 disabled:opacity-50"
              >
                <%= if @testing_elevenlabs, do: "Testing...", else: "Test Connection" %>
              </button>
              <%= if @elevenlabs_status do %>
                <span class={status_class(@elevenlabs_status)}>
                  <%= status_text(@elevenlabs_status) %>
                </span>
              <% end %>
            </div>
          </div>
        </div>

        <!-- Save Button -->
        <div class="flex justify-end">
          <button
            type="submit"
            class="px-6 py-3 bg-blue-600 text-white font-medium rounded-lg hover:bg-blue-700 transition-colors"
          >
            Save Settings
          </button>
        </div>
      </form>
    </div>
    """
  end

  @impl true
  def handle_event("validate", params, socket) do
    settings =
      socket.assigns.settings
      |> Map.merge(%{
        "orpheus_url" => params["orpheus_url"] || "",
        "orpheus_voice" => params["orpheus_voice"] || "",
        "elevenlabs_api_key" => params["elevenlabs_api_key"] || "",
        "elevenlabs_voice_id" => params["elevenlabs_voice_id"] || "",
        "elevenlabs_model" => params["elevenlabs_model"] || ""
      })

    {:noreply, assign(socket, settings: settings, saved: false)}
  end

  @impl true
  def handle_event("save", params, socket) do
    settings = %{
      "orpheus_url" => params["orpheus_url"],
      "orpheus_voice" => params["orpheus_voice"],
      "elevenlabs_api_key" => params["elevenlabs_api_key"],
      "elevenlabs_voice_id" => params["elevenlabs_voice_id"],
      "elevenlabs_model" => params["elevenlabs_model"]
    }

    Settings.update_all(settings)

    {:noreply, assign(socket, settings: Settings.all(), saved: true, error: nil)}
  end

  @impl true
  def handle_event("test_orpheus", _params, socket) do
    send(self(), :do_test_orpheus)
    {:noreply, assign(socket, testing_orpheus: true, orpheus_status: nil)}
  end

  @impl true
  def handle_event("test_elevenlabs", _params, socket) do
    send(self(), :do_test_elevenlabs)
    {:noreply, assign(socket, testing_elevenlabs: true, elevenlabs_status: nil)}
  end

  @impl true
  def handle_info(:do_test_orpheus, socket) do
    url = socket.assigns.settings["orpheus_url"]
    status = TtsClient.TTS.OrpheusClient.health_check(url)

    {:noreply, assign(socket, testing_orpheus: false, orpheus_status: status)}
  end

  @impl true
  def handle_info(:do_test_elevenlabs, socket) do
    api_key = socket.assigns.settings["elevenlabs_api_key"]

    status =
      case TtsClient.TTS.ElevenLabsClient.list_voices(api_key) do
        {:ok, voices} -> {:ok, length(voices)}
        error -> error
      end

    {:noreply, assign(socket, testing_elevenlabs: false, elevenlabs_status: status)}
  end

  defp status_class(:ok), do: "text-green-600 font-medium"
  defp status_class({:ok, _}), do: "text-green-600 font-medium"
  defp status_class(_), do: "text-red-600 font-medium"

  defp status_text(:ok), do: "Connected!"
  defp status_text({:ok, count}), do: "Connected! (#{count} voices available)"
  defp status_text({:error, :invalid_api_key}), do: "Invalid API key"
  defp status_text({:error, {:connection_error, _}}), do: "Connection failed"
  defp status_text({:error, reason}), do: "Error: #{inspect(reason)}"
end
