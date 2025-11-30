defmodule TtsClientWeb.TTSStreamingLive do
  use TtsClientWeb, :live_view

  alias TtsClient.TTS.{StreamingJob, GPU}
  alias TtsClient.Settings

  @impl true
  def mount(_params, _session, socket) do
    gpu_info = GPU.get_memory_info()
    settings = Settings.all()

    {:ok,
     assign(socket,
       text: "",
       voice: settings["orpheus_voice"] || "tara",
       backend: Settings.tts_backend(),
       elevenlabs_configured: Settings.elevenlabs_configured?(),
       job_pid: nil,
       job_id: nil,
       status: nil,
       current_chunk: 0,
       total_chunks: 0,
       chunks_completed: 0,
       error: nil,
       final_wav: nil,
       gpu_info: gpu_info,
       is_playing: false,
       show_replay_dialog: false
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6" id="tts-container" phx-hook="AudioPlayer">
      <!-- Replay/Redo Dialog Modal -->
      <%= if @show_replay_dialog do %>
        <div class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
          <div class="bg-white rounded-lg shadow-xl p-6 max-w-md w-full mx-4">
            <h3 class="text-xl font-semibold mb-4">Audio Already Generated</h3>
            <p class="text-gray-600 mb-6">
              You have already synthesized this text. Would you like to replay the existing audio or generate new audio?
            </p>
            <div class="flex gap-3">
              <button
                type="button"
                phx-click="replay_existing"
                class="flex-1 py-2 px-4 bg-green-600 text-white font-medium rounded-lg hover:bg-green-700 transition-colors"
              >
                Replay Existing
              </button>
              <button
                type="button"
                phx-click="redo_synthesis"
                class="flex-1 py-2 px-4 bg-blue-600 text-white font-medium rounded-lg hover:bg-blue-700 transition-colors"
              >
                Generate New
              </button>
              <button
                type="button"
                phx-click="cancel_dialog"
                class="py-2 px-4 bg-gray-200 text-gray-700 font-medium rounded-lg hover:bg-gray-300 transition-colors"
              >
                Cancel
              </button>
            </div>
          </div>
        </div>
      <% end %>

      <div class="flex justify-between items-center mb-6">
        <h1 class="text-3xl font-bold">Streaming Text-to-Speech</h1>
        <a href={~p"/settings"} class="text-blue-600 hover:underline flex items-center gap-1">
          <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
            <path fill-rule="evenodd" d="M11.49 3.17c-.38-1.56-2.6-1.56-2.98 0a1.532 1.532 0 01-2.286.948c-1.372-.836-2.942.734-2.106 2.106.54.886.061 2.042-.947 2.287-1.561.379-1.561 2.6 0 2.978a1.532 1.532 0 01.947 2.287c-.836 1.372.734 2.942 2.106 2.106a1.532 1.532 0 012.287.947c.379 1.561 2.6 1.561 2.978 0a1.533 1.533 0 012.287-.947c1.372.836 2.942-.734 2.106-2.106a1.533 1.533 0 01.947-2.287c1.561-.379 1.561-2.6 0-2.978a1.532 1.532 0 01-.947-2.287c.836-1.372-.734-2.942-2.106-2.106a1.532 1.532 0 01-2.287-.947zM10 13a3 3 0 100-6 3 3 0 000 6z" clip-rule="evenodd" />
          </svg>
          Settings
        </a>
      </div>

      <!-- Backend Toggle -->
      <div class="mb-6 p-4 bg-white rounded-lg shadow border">
        <h2 class="text-lg font-semibold mb-3">TTS Backend</h2>
        <div class="flex gap-4">
          <label class={"flex items-center gap-2 p-3 rounded-lg border-2 cursor-pointer transition-colors #{if @backend == :orpheus, do: "border-green-500 bg-green-50", else: "border-gray-200 hover:border-gray-300"}"}>
            <input
              type="radio"
              name="backend"
              value="orpheus"
              checked={@backend == :orpheus}
              phx-click="set_backend"
              phx-value-backend="orpheus"
              disabled={@status == :processing}
              class="text-green-600"
            />
            <div>
              <span class="font-medium">Local Orpheus</span>
              <p class="text-xs text-gray-500">GPU-accelerated, runs locally</p>
            </div>
          </label>

          <label class={"flex items-center gap-2 p-3 rounded-lg border-2 cursor-pointer transition-colors #{if @backend == :elevenlabs, do: "border-purple-500 bg-purple-50", else: "border-gray-200 hover:border-gray-300"} #{unless @elevenlabs_configured, do: "opacity-50"}"}>
            <input
              type="radio"
              name="backend"
              value="elevenlabs"
              checked={@backend == :elevenlabs}
              phx-click="set_backend"
              phx-value-backend="elevenlabs"
              disabled={@status == :processing or not @elevenlabs_configured}
              class="text-purple-600"
            />
            <div>
              <span class="font-medium">ElevenLabs</span>
              <%= if @elevenlabs_configured do %>
                <p class="text-xs text-gray-500">Cloud API, high quality</p>
              <% else %>
                <p class="text-xs text-red-500">Not configured - check Settings</p>
              <% end %>
            </div>
          </label>
        </div>
      </div>

      <!-- GPU Status (only show for Orpheus) -->
      <%= if @backend == :orpheus do %>
        <div class="mb-6 p-4 bg-gray-100 rounded-lg">
          <h2 class="text-lg font-semibold mb-2">GPU Status</h2>
        <%= case @gpu_info do %>
          <% {:ok, info} -> %>
            <div class="grid grid-cols-3 gap-4 text-sm">
              <div>
                <span class="text-gray-600">Total VRAM:</span>
                <span class="font-medium"><%= info.total %> MB</span>
              </div>
              <div>
                <span class="text-gray-600">Used:</span>
                <span class="font-medium"><%= info.used %> MB</span>
              </div>
              <div>
                <span class="text-gray-600">Free:</span>
                <span class="font-medium text-green-600"><%= info.free %> MB</span>
              </div>
            </div>
          <% {:error, _} -> %>
            <p class="text-yellow-600">GPU info unavailable</p>
        <% end %>
        </div>
      <% end %>

      <form phx-submit="synthesize" phx-change="validate" class="space-y-4">
        <div>
          <label for="text" class="block text-sm font-medium text-gray-700 mb-2">
            Enter text to synthesize
          </label>
          <textarea
            id="text"
            name="text"
            rows="8"
            class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
            placeholder="Type or paste your text here. Each sentence will be processed and played as it's ready..."
            disabled={@status in [:processing]}
          ><%= @text %></textarea>
          <p class="mt-1 text-sm text-gray-500">
            <%= String.length(@text) %> characters
          </p>
        </div>

        <div>
          <label for="voice" class="block text-sm font-medium text-gray-700 mb-2">
            Default Voice (for Orpheus)
          </label>
          <select
            id="voice"
            name="voice"
            class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500"
            disabled={@status in [:processing]}
          >
            <%= for voice <- ~w(tara leah jess leo dan mia zac zoe) do %>
              <option value={voice} selected={@voice == voice}><%= String.capitalize(voice) %></option>
            <% end %>
          </select>
          <p class="mt-1 text-xs text-gray-500">
            Or use inline format: <code class="bg-gray-100 px-1 rounded">{"{voice}"}: text</code>
          </p>
        </div>

        <button
          type="submit"
          disabled={@text == "" or @status in [:processing]}
          class="w-full py-3 px-4 bg-blue-600 text-white font-medium rounded-lg hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed transition-colors"
        >
          <%= if @status == :processing do %>
            Processing...
          <% else %>
            Stream & Play
          <% end %>
        </button>
      </form>

      <%= if @status do %>
        <div class="mt-6 p-4 bg-gray-50 rounded-lg">
          <h2 class="text-lg font-semibold mb-3">Streaming Status</h2>

          <div class="space-y-3">
            <div class="flex justify-between text-sm">
              <span class="text-gray-600">Status:</span>
              <span class={"font-medium #{status_color(@status)}"}>
                <%= format_status(@status) %>
              </span>
            </div>

            <%= if @total_chunks > 0 do %>
              <div>
                <div class="flex justify-between text-sm mb-1">
                  <span>Synthesis Progress</span>
                  <span><%= @chunks_completed %>/<%= @total_chunks %> sentences</span>
                </div>
                <div class="w-full bg-gray-200 rounded-full h-2">
                  <div
                    class="bg-blue-600 h-2 rounded-full transition-all duration-300"
                    style={"width: #{progress_percent(@chunks_completed, @total_chunks)}%"}
                  ></div>
                </div>
              </div>

              <div>
                <div class="flex justify-between text-sm mb-1">
                  <span>Playback Queue</span>
                  <span id="playback-status">Waiting...</span>
                </div>
                <div class="w-full bg-gray-200 rounded-full h-2">
                  <div
                    id="playback-progress"
                    class="bg-green-500 h-2 rounded-full transition-all duration-300"
                    style="width: 0%"
                  ></div>
                </div>
              </div>
            <% end %>
          </div>

          <%= if @error do %>
            <div class="mt-3 p-3 bg-red-100 border border-red-300 rounded-lg text-red-700">
              <strong>Error:</strong> <%= inspect(@error) %>
            </div>
          <% end %>

          <%= if @final_wav do %>
            <div class="mt-4 space-y-3">
              <p class="text-green-600 font-medium">Complete audio ready for download!</p>
              <a
                href={~p"/api/tts/stream/download/#{@job_id}"}
                download="speech.wav"
                class="inline-block py-2 px-4 bg-green-600 text-white rounded-lg hover:bg-green-700 transition-colors"
              >
                Download Full WAV
              </a>
            </div>
          <% end %>
        </div>
      <% end %>

      <div class="mt-6 p-4 bg-blue-50 rounded-lg">
        <h3 class="font-semibold text-blue-800 mb-2">How Streaming Works</h3>
        <ul class="text-sm text-blue-700 space-y-1">
          <li>1. Text is split into sentences/lines</li>
          <li>2. Each chunk is synthesized one at a time</li>
          <li>3. Audio plays immediately as each chunk is ready</li>
          <li>4. Full WAV available for download when complete</li>
        </ul>
      </div>

      <%= if @backend == :orpheus do %>
        <div class="mt-4 p-4 bg-purple-50 rounded-lg">
          <h3 class="font-semibold text-purple-800 mb-2">Multi-Speaker & Emotion Tags (Orpheus)</h3>
          <div class="text-sm text-purple-700 space-y-2">
            <p><strong>Multi-speaker format:</strong> Use <code class="bg-purple-100 px-1 rounded">{"{voice}"}: text</code> per line</p>
            <p><strong>Available voices:</strong> tara, leah, jess, leo, dan, mia, zac, zoe</p>
            <p><strong>Emotion tags:</strong>
              <code class="bg-purple-100 px-1 rounded text-xs">&lt;laugh&gt;</code>
              <code class="bg-purple-100 px-1 rounded text-xs">&lt;chuckle&gt;</code>
              <code class="bg-purple-100 px-1 rounded text-xs">&lt;sigh&gt;</code>
              <code class="bg-purple-100 px-1 rounded text-xs">&lt;groan&gt;</code>
              <code class="bg-purple-100 px-1 rounded text-xs">&lt;yawn&gt;</code>
              <code class="bg-purple-100 px-1 rounded text-xs">&lt;gasp&gt;</code>
            </p>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"text" => text} = params, socket) do
    voice = Map.get(params, "voice", socket.assigns.voice)
    {:noreply, assign(socket, text: text, voice: voice)}
  end

  @impl true
  def handle_event("set_backend", %{"backend" => backend}, socket) do
    backend_atom = String.to_existing_atom(backend)
    Settings.set("tts_backend", backend)
    {:noreply, assign(socket, backend: backend_atom)}
  end

  @impl true
  def handle_event("synthesize", %{"text" => text, "voice" => voice}, socket) do
    # Check if we have an existing completed WAV
    if socket.assigns.final_wav && socket.assigns.job_id do
      # Show dialog asking whether to replay or redo
      {:noreply, assign(socket, text: text, voice: voice, show_replay_dialog: true)}
    else
      start_new_synthesis(socket, text, voice)
    end
  end

  @impl true
  def handle_event("replay_existing", _params, socket) do
    job_id = socket.assigns.job_id

    # Get the stored job and replay its audio
    case :ets.lookup(:tts_jobs, job_id) do
      [{^job_id, pid}] when is_pid(pid) ->
        state = StreamingJob.get_state(pid)
        wav_parts_map = state.wav_parts
        total_chunks = map_size(wav_parts_map)

        # Push replay event with all the existing WAV chunks
        socket =
          socket
          |> assign(show_replay_dialog: false, status: :replaying, chunks_completed: 0)
          |> push_event("tts_start", %{total_chunks: total_chunks})

        # Send all chunks to the client in order (sorted by index)
        socket =
          wav_parts_map
          |> Enum.sort_by(fn {index, _wav} -> index end)
          |> Enum.reduce(socket, fn {index, wav_data}, acc ->
            wav_base64 = Base.encode64(wav_data)
            push_event(acc, "tts_chunk", %{index: index, wav: wav_base64})
          end)

        {:noreply,
         socket
         |> assign(chunks_completed: total_chunks, status: :completed)
         |> push_event("tts_complete", %{})}

      _ ->
        # Job not found, start fresh
        {:noreply, assign(socket, show_replay_dialog: false, error: "Previous audio not found")}
    end
  end

  @impl true
  def handle_event("redo_synthesis", _params, socket) do
    # Close dialog and start new synthesis
    socket = assign(socket, show_replay_dialog: false, final_wav: nil)
    start_new_synthesis(socket, socket.assigns.text, socket.assigns.voice)
  end

  @impl true
  def handle_event("cancel_dialog", _params, socket) do
    {:noreply, assign(socket, show_replay_dialog: false)}
  end

  defp start_new_synthesis(socket, text, voice) do
    backend = socket.assigns.backend
    opts = [voice: voice, backend: backend]

    case StreamingJob.start_link(text, opts) do
      {:ok, pid} ->
        state = StreamingJob.get_state(pid)
        StreamingJob.subscribe(state.id)

        # Store for download
        :ets.insert(:tts_jobs, {state.id, pid})

        {:noreply,
         socket
         |> assign(
           text: text,
           voice: voice,
           job_pid: pid,
           job_id: state.id,
           status: :processing,
           current_chunk: 0,
           total_chunks: state.total_chunks,
           chunks_completed: 0,
           error: nil,
           final_wav: nil
         )
         |> push_event("tts_start", %{total_chunks: state.total_chunks})}

      {:error, reason} ->
        {:noreply, assign(socket, error: reason)}
    end
  end

  @impl true
  def handle_info({:tts_job_status, _job_id, status_map}, socket) do
    {:noreply,
     assign(socket,
       status: status_map.status,
       current_chunk: status_map.current_chunk,
       chunks_completed: status_map.chunks_completed
     )}
  end

  @impl true
  def handle_info({:tts_chunk_ready, _job_id, index, wav_data}, socket) do
    # Send WAV as base64 to client for immediate playback
    wav_base64 = Base.encode64(wav_data)

    {:noreply,
     socket
     |> assign(chunks_completed: index + 1)
     |> push_event("tts_chunk", %{index: index, wav: wav_base64})}
  end

  @impl true
  def handle_info({:tts_job_complete, _job_id, _final_wav}, socket) do
    {:noreply,
     socket
     |> assign(status: :completed, final_wav: true)
     |> push_event("tts_complete", %{})
     |> assign(gpu_info: GPU.get_memory_info())}
  end

  @impl true
  def handle_info({:tts_job_error, _job_id, error}, socket) do
    {:noreply,
     socket
     |> assign(status: :failed, error: error)
     |> push_event("tts_error", %{error: inspect(error)})}
  end

  defp format_status(:processing), do: "Synthesizing..."
  defp format_status(:replaying), do: "Replaying..."
  defp format_status(:completed), do: "Completed"
  defp format_status(:failed), do: "Failed"
  defp format_status(status), do: to_string(status)

  defp status_color(:completed), do: "text-green-600"
  defp status_color(:failed), do: "text-red-600"
  defp status_color(_), do: "text-blue-600"

  defp progress_percent(current, total) when total > 0, do: round(current / total * 100)
  defp progress_percent(_, _), do: 0
end
