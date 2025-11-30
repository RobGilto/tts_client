defmodule TtsClientWeb.TTSLive do
  use TtsClientWeb, :live_view

  alias TtsClient.TTS.{Job, GPU}

  @impl true
  def mount(_params, _session, socket) do
    gpu_info = get_gpu_info()

    {:ok,
     assign(socket,
       text: "",
       voice: "tara",
       job_pid: nil,
       job_id: nil,
       job_status: nil,
       progress: 0,
       total_chunks: 0,
       error: nil,
       result: nil,
       gpu_info: gpu_info
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <h1 class="text-3xl font-bold mb-6">Text-to-Speech</h1>

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
            <p class="text-yellow-600">GPU info unavailable - using default chunk size</p>
        <% end %>
      </div>

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
            placeholder="Type or paste your text here..."
            disabled={@job_status in [:initializing, :chunking, :processing, :stitching]}
          ><%= @text %></textarea>
          <p class="mt-1 text-sm text-gray-500">
            <%= String.length(@text) %> characters
          </p>
        </div>

        <div>
          <label for="voice" class="block text-sm font-medium text-gray-700 mb-2">
            Voice
          </label>
          <select
            id="voice"
            name="voice"
            class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500"
            disabled={@job_status in [:initializing, :chunking, :processing, :stitching]}
          >
            <option value="tara" selected={@voice == "tara"}>Tara</option>
          </select>
        </div>

        <button
          type="submit"
          disabled={@text == "" or @job_status in [:initializing, :chunking, :processing, :stitching]}
          class="w-full py-3 px-4 bg-blue-600 text-white font-medium rounded-lg hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed transition-colors"
        >
          <%= if @job_status in [:initializing, :chunking, :processing, :stitching] do %>
            Processing...
          <% else %>
            Synthesize Speech
          <% end %>
        </button>
      </form>

      <%= if @job_status do %>
        <div class="mt-6 p-4 bg-gray-50 rounded-lg">
          <h2 class="text-lg font-semibold mb-3">Job Status</h2>

          <div class="mb-4">
            <div class="flex justify-between text-sm mb-1">
              <span class="text-gray-600">Status:</span>
              <span class={"font-medium #{status_color(@job_status)}"}>
                <%= format_status(@job_status) %>
              </span>
            </div>

            <%= if @total_chunks > 0 do %>
              <div class="mt-2">
                <div class="flex justify-between text-sm mb-1">
                  <span>Progress</span>
                  <span><%= @progress %>/<%= @total_chunks %> chunks</span>
                </div>
                <div class="w-full bg-gray-200 rounded-full h-2">
                  <div
                    class="bg-blue-600 h-2 rounded-full transition-all duration-300"
                    style={"width: #{progress_percent(@progress, @total_chunks)}%"}
                  ></div>
                </div>
              </div>
            <% end %>
          </div>

          <%= if @error do %>
            <div class="p-3 bg-red-100 border border-red-300 rounded-lg text-red-700">
              <strong>Error:</strong> <%= inspect(@error) %>
            </div>
          <% end %>

          <%= if @result do %>
            <div class="space-y-3">
              <p class="text-green-600 font-medium">Audio ready!</p>

              <audio controls class="w-full">
                <source src={~p"/api/tts/download/#{@job_id}"} type="audio/wav" />
                Your browser does not support the audio element.
              </audio>

              <a
                href={~p"/api/tts/download/#{@job_id}"}
                download="speech.wav"
                class="inline-block py-2 px-4 bg-green-600 text-white rounded-lg hover:bg-green-700 transition-colors"
              >
                Download WAV
              </a>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"text" => text, "voice" => voice}, socket) do
    {:noreply, assign(socket, text: text, voice: voice)}
  end

  def handle_event("validate", %{"text" => text}, socket) do
    {:noreply, assign(socket, text: text)}
  end

  @impl true
  def handle_event("synthesize", %{"text" => text, "voice" => voice}, socket) do
    case Job.start_link(text, voice: voice) do
      {:ok, pid} ->
        state = Job.get_state(pid)
        Job.subscribe(state.id)

        # Store job result in ETS for download
        :ets.insert(:tts_jobs, {state.id, pid})

        {:noreply,
         assign(socket,
           text: text,
           voice: voice,
           job_pid: pid,
           job_id: state.id,
           job_status: state.status,
           progress: 0,
           total_chunks: 0,
           error: nil,
           result: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: reason)}
    end
  end

  @impl true
  def handle_info({:tts_job_progress, _job_id, state}, socket) do
    socket =
      socket
      |> assign(
        job_status: state.status,
        progress: state.progress,
        total_chunks: state.total_chunks || 0,
        error: state.error,
        result: state.result
      )
      |> maybe_refresh_gpu()

    {:noreply, socket}
  end

  defp get_gpu_info do
    GPU.get_memory_info()
  end

  defp maybe_refresh_gpu(socket) do
    if socket.assigns.job_status in [:completed, :failed] do
      assign(socket, gpu_info: get_gpu_info())
    else
      socket
    end
  end

  defp format_status(:initializing), do: "Initializing..."
  defp format_status(:chunking), do: "Chunking text..."
  defp format_status(:processing), do: "Processing chunks..."
  defp format_status(:stitching), do: "Stitching audio..."
  defp format_status(:completed), do: "Completed"
  defp format_status(:failed), do: "Failed"
  defp format_status(status), do: to_string(status)

  defp status_color(:completed), do: "text-green-600"
  defp status_color(:failed), do: "text-red-600"
  defp status_color(_), do: "text-blue-600"

  defp progress_percent(progress, total) when total > 0, do: round(progress / total * 100)
  defp progress_percent(_, _), do: 0
end
