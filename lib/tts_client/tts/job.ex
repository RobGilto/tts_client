defmodule TtsClient.TTS.Job do
  @moduledoc """
  GenServer for managing TTS jobs.
  Handles text chunking, sequential TTS processing, and WAV stitching.
  Broadcasts progress updates via PubSub.
  """

  use GenServer
  require Logger

  alias TtsClient.TTS.{Chunker, Client, WavStitcher, GPU}
  alias Phoenix.PubSub

  @pubsub TtsClient.PubSub

  defstruct [
    :id,
    :text,
    :voice,
    :chunks,
    :status,
    :progress,
    :total_chunks,
    :result,
    :error,
    :started_at,
    :completed_at,
    wav_parts: []
  ]

  # Client API

  @doc """
  Starts a new TTS job.

  ## Options
    - :voice - Voice to use (default: "tara")
    - :tts_url - TTS service URL
  """
  def start_link(text, opts \\ []) do
    GenServer.start_link(__MODULE__, {text, opts})
  end

  @doc """
  Gets the current job state.
  """
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @doc """
  Subscribes to job progress updates.
  Messages will be sent as {:tts_job_progress, job_id, state}
  """
  def subscribe(job_id) do
    PubSub.subscribe(@pubsub, "tts_job:#{job_id}")
  end

  @doc """
  Unsubscribes from job progress updates.
  """
  def unsubscribe(job_id) do
    PubSub.unsubscribe(@pubsub, "tts_job:#{job_id}")
  end

  # Server Callbacks

  @impl true
  def init({text, opts}) do
    job_id = generate_job_id()
    voice = Keyword.get(opts, :voice, "tara")

    state = %__MODULE__{
      id: job_id,
      text: text,
      voice: voice,
      status: :initializing,
      progress: 0,
      started_at: DateTime.utc_now()
    }

    # Start processing asynchronously
    send(self(), {:start_processing, opts})

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({:start_processing, opts}, state) do
    state = %{state | status: :chunking}
    broadcast_progress(state)

    # Get GPU info for logging
    gpu_info = GPU.get_memory_info()
    Logger.info("Starting TTS job #{state.id}, GPU: #{inspect(gpu_info)}")

    # Chunk the text
    {:ok, chunks} = Chunker.chunk_by_vram(state.text)
    total_chunks = length(chunks)

    Logger.info("Text chunked into #{total_chunks} parts")

    state = %{state | chunks: chunks, total_chunks: total_chunks, status: :processing}
    broadcast_progress(state)

    # Process chunks sequentially
    send(self(), {:process_chunk, 0, opts})

    {:noreply, state}
  end

  @impl true
  def handle_info({:process_chunk, index, opts}, %{chunks: chunks, total_chunks: total} = state)
      when index < total do
    chunk = Enum.at(chunks, index)
    tts_opts = Keyword.take(opts, [:url, :voice, :timeout])

    state = %{state | progress: index}
    broadcast_progress(state)

    case Client.synthesize(chunk, tts_opts) do
      {:ok, wav_data} ->
        state = %{state | wav_parts: state.wav_parts ++ [wav_data], progress: index + 1}
        broadcast_progress(state)

        # Continue to next chunk
        send(self(), {:process_chunk, index + 1, opts})
        {:noreply, state}

      {:error, reason} ->
        Logger.error("TTS job #{state.id} failed at chunk #{index}: #{inspect(reason)}")
        state = %{state | status: :failed, error: reason, completed_at: DateTime.utc_now()}
        broadcast_progress(state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:process_chunk, index, _opts}, %{total_chunks: total} = state)
      when index >= total do
    # All chunks processed, stitch together
    state = %{state | status: :stitching}
    broadcast_progress(state)

    case WavStitcher.stitch(state.wav_parts) do
      {:ok, final_wav} ->
        state = %{state | status: :completed, result: final_wav, completed_at: DateTime.utc_now()}
        broadcast_progress(state)
        Logger.info("TTS job #{state.id} completed, output size: #{byte_size(final_wav)} bytes")
        {:noreply, state}

      {:error, reason} ->
        Logger.error("TTS job #{state.id} stitching failed: #{inspect(reason)}")
        state = %{state | status: :failed, error: reason, completed_at: DateTime.utc_now()}
        broadcast_progress(state)
        {:noreply, state}
    end
  end

  defp generate_job_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp broadcast_progress(state) do
    PubSub.broadcast(@pubsub, "tts_job:#{state.id}", {:tts_job_progress, state.id, state})
  end
end
