defmodule TtsClient.TTS.StreamingJob do
  @moduledoc """
  Streaming TTS job processor.

  Uses a pipeline approach:
  1. Split text into sentences
  2. Start synthesizing first chunk immediately
  3. As each chunk completes, broadcast it for playback AND start next chunk
  4. Client plays chunks as they arrive (minimal latency)
  5. At the end, stitch all WAVs together for download
  """

  use GenServer
  require Logger

  alias TtsClient.TTS.{Chunker, Client, WavStitcher}
  alias Phoenix.PubSub

  @pubsub TtsClient.PubSub

  defstruct [
    :id,
    :text,
    :voice,
    :backend,
    :chunks,
    :status,
    :current_chunk,
    :total_chunks,
    :error,
    :started_at,
    :completed_at,
    :tts_opts,
    wav_parts: %{},  # Map of index => wav_binary for guaranteed ordering
    durations: %{}   # Map of index => duration_ms
  ]

  # Client API

  @doc """
  Starts a new streaming TTS job.

  Options:
    - :voice - Voice to use (default: "tara")
    - :backend - TTS backend (:orpheus or :elevenlabs)
    - :url - TTS service URL (for Orpheus)
    - :min_sentence_length - Minimum chars to group short sentences (default: 20)
  """
  def start_link(text, opts \\ []) do
    GenServer.start_link(__MODULE__, {text, opts})
  end

  def get_state(pid), do: GenServer.call(pid, :get_state)

  def get_result(pid), do: GenServer.call(pid, :get_result)

  @doc """
  Subscribe to streaming updates.
  Messages:
    - {:tts_chunk_ready, job_id, chunk_index, wav_binary}
    - {:tts_job_status, job_id, status_map}
    - {:tts_job_complete, job_id, final_wav_binary}
    - {:tts_job_error, job_id, error}
  """
  def subscribe(job_id) do
    PubSub.subscribe(@pubsub, "tts_stream:#{job_id}")
  end

  def unsubscribe(job_id) do
    PubSub.unsubscribe(@pubsub, "tts_stream:#{job_id}")
  end

  # Server Callbacks

  @impl true
  def init({text, opts}) do
    job_id = generate_job_id()
    voice = Keyword.get(opts, :voice, "tara")
    backend = Keyword.get(opts, :backend, :orpheus)
    min_length = Keyword.get(opts, :min_sentence_length, 20)

    # Split into sentences with voice context (prepends voice to chunks without one)
    chunks = Chunker.chunk_by_sentences(text, min_length: min_length, default_voice: voice)

    state = %__MODULE__{
      id: job_id,
      text: text,
      backend: backend,
      voice: voice,
      chunks: chunks,
      total_chunks: length(chunks),
      current_chunk: 0,
      status: :ready,
      started_at: DateTime.utc_now(),
      tts_opts: Keyword.take(opts, [:url, :timeout, :backend])
    }

    # Start processing immediately
    send(self(), :start_pipeline)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:get_result, _from, %{status: :completed, wav_parts: parts} = state) do
    # Convert map to ordered list for stitching
    ordered_parts = get_ordered_wav_parts(parts)
    case WavStitcher.stitch(ordered_parts) do
      {:ok, wav} -> {:reply, {:ok, wav}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:get_result, _from, state) do
    {:reply, {:error, :not_completed}, state}
  end

  @impl true
  def handle_info(:start_pipeline, state) do
    state = %{state | status: :processing}
    broadcast_status(state)

    Logger.info("Starting streaming TTS job #{state.id} with #{state.total_chunks} chunks")

    # Start first chunk
    send(self(), {:synthesize_chunk, 0})

    {:noreply, state}
  end

  @impl true
  def handle_info({:synthesize_chunk, index}, %{chunks: chunks, total_chunks: total} = state)
      when index < total do
    chunk_text = Enum.at(chunks, index)
    state = %{state | current_chunk: index}
    broadcast_status(state)

    Logger.debug("Synthesizing chunk #{index + 1}/#{total}: #{String.slice(chunk_text, 0, 50)}...")

    tts_opts = [{:voice, state.voice} | state.tts_opts]
    start_time = System.monotonic_time(:millisecond)

    case Client.synthesize(chunk_text, tts_opts) do
      {:ok, wav_data} ->
        duration = System.monotonic_time(:millisecond) - start_time

        # Store the WAV part by index for guaranteed ordering
        state = %{state |
          wav_parts: Map.put(state.wav_parts, index, wav_data),
          durations: Map.put(state.durations, index, duration)
        }

        # Broadcast chunk ready for immediate playback
        broadcast_chunk_ready(state.id, index, wav_data)

        Logger.debug("Chunk #{index + 1} ready: #{byte_size(wav_data)} bytes in #{duration}ms")

        # Continue to next chunk
        send(self(), {:synthesize_chunk, index + 1})

        {:noreply, state}

      {:error, reason} ->
        Logger.error("Streaming job #{state.id} failed at chunk #{index}: #{inspect(reason)}")
        state = %{state | status: :failed, error: reason, completed_at: DateTime.utc_now()}
        broadcast_error(state.id, reason)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:synthesize_chunk, index}, %{total_chunks: total} = state)
      when index >= total do
    # All chunks done - stitch final WAV
    Logger.info("All chunks complete, stitching final WAV...")

    # Convert map to ordered list for stitching
    ordered_parts = get_ordered_wav_parts(state.wav_parts)

    case WavStitcher.stitch(ordered_parts) do
      {:ok, final_wav} ->
        state = %{state | status: :completed, completed_at: DateTime.utc_now()}

        total_duration = state.durations |> Map.values() |> Enum.sum()
        Logger.info("Streaming job #{state.id} completed in #{total_duration}ms, " <>
                   "output: #{byte_size(final_wav)} bytes")

        broadcast_complete(state.id, final_wav)
        broadcast_status(state)

        {:noreply, state}

      {:error, reason} ->
        state = %{state | status: :failed, error: reason, completed_at: DateTime.utc_now()}
        broadcast_error(state.id, reason)
        {:noreply, state}
    end
  end

  defp generate_job_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  @doc """
  Converts wav_parts map to an ordered list sorted by index.
  """
  def get_ordered_wav_parts(wav_parts_map) do
    wav_parts_map
    |> Enum.sort_by(fn {index, _wav} -> index end)
    |> Enum.map(fn {_index, wav} -> wav end)
  end

  defp broadcast_status(state) do
    status = %{
      status: state.status,
      current_chunk: state.current_chunk,
      total_chunks: state.total_chunks,
      chunks_completed: map_size(state.wav_parts)
    }
    PubSub.broadcast(@pubsub, "tts_stream:#{state.id}", {:tts_job_status, state.id, status})
  end

  defp broadcast_chunk_ready(job_id, index, wav_data) do
    PubSub.broadcast(@pubsub, "tts_stream:#{job_id}", {:tts_chunk_ready, job_id, index, wav_data})
  end

  defp broadcast_complete(job_id, final_wav) do
    PubSub.broadcast(@pubsub, "tts_stream:#{job_id}", {:tts_job_complete, job_id, final_wav})
  end

  defp broadcast_error(job_id, error) do
    PubSub.broadcast(@pubsub, "tts_stream:#{job_id}", {:tts_job_error, job_id, error})
  end
end
