defmodule TtsClient.TTS.GPU do
  @moduledoc """
  GPU monitoring module using nvidia-smi for VRAM detection.
  """

  @doc """
  Gets current GPU memory information.
  Returns {:ok, %{total: mb, used: mb, free: mb}} or {:error, reason}
  """
  def get_memory_info do
    case System.cmd("nvidia-smi", [
           "--query-gpu=memory.total,memory.used,memory.free",
           "--format=csv,noheader,nounits"
         ]) do
      {output, 0} ->
        parse_memory_output(output)

      {_, _} ->
        {:error, :nvidia_smi_failed}
    end
  rescue
    ErlangError -> {:error, :nvidia_smi_not_found}
  end

  @doc """
  Gets available VRAM in MB.
  """
  def available_vram do
    case get_memory_info() do
      {:ok, %{free: free}} -> {:ok, free}
      error -> error
    end
  end

  @doc """
  Calculates recommended chunk size based on available VRAM.

  Heuristic: More VRAM allows for longer text chunks.
  - < 2GB free: ~200 chars per chunk (conservative)
  - 2-4GB free: ~500 chars per chunk
  - 4-8GB free: ~1000 chars per chunk
  - > 8GB free: ~2000 chars per chunk
  """
  def recommended_chunk_size do
    case available_vram() do
      {:ok, free_mb} ->
        chunk_size =
          cond do
            free_mb < 2000 -> 200
            free_mb < 4000 -> 500
            free_mb < 8000 -> 1000
            true -> 2000
          end

        {:ok, chunk_size}

      error ->
        error
    end
  end

  @doc """
  Checks if GPU has enough VRAM for TTS processing.
  Minimum recommended: 1GB free
  """
  def has_capacity?(min_mb \\ 1000) do
    case available_vram() do
      {:ok, free} -> free >= min_mb
      _ -> false
    end
  end

  defp parse_memory_output(output) do
    output
    |> String.trim()
    |> String.split("\n")
    |> List.first()
    |> parse_memory_line()
  end

  defp parse_memory_line(nil), do: {:error, :no_gpu_found}

  defp parse_memory_line(line) do
    case String.split(line, ",") |> Enum.map(&String.trim/1) do
      [total, used, free] ->
        {:ok,
         %{
           total: String.to_integer(total),
           used: String.to_integer(used),
           free: String.to_integer(free)
         }}

      _ ->
        {:error, :parse_error}
    end
  end
end
