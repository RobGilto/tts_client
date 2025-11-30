defmodule TtsClientWeb.TTSController do
  use TtsClientWeb, :controller

  alias TtsClient.TTS.{Job, StreamingJob}

  def download(conn, %{"job_id" => job_id}) do
    case :ets.lookup(:tts_jobs, job_id) do
      [{^job_id, pid}] when is_pid(pid) ->
        if Process.alive?(pid) do
          state = Job.get_state(pid)

          case state.status do
            :completed ->
              conn
              |> put_resp_content_type("audio/wav")
              |> put_resp_header("content-disposition", ~s(attachment; filename="speech.wav"))
              |> send_resp(200, state.result)

            status ->
              conn
              |> put_status(202)
              |> json(%{status: status, message: "Job not yet completed"})
          end
        else
          conn
          |> put_status(410)
          |> json(%{error: "Job process no longer available"})
        end

      [] ->
        conn
        |> put_status(404)
        |> json(%{error: "Job not found"})
    end
  end

  def download_stream(conn, %{"job_id" => job_id}) do
    case :ets.lookup(:tts_jobs, job_id) do
      [{^job_id, pid}] when is_pid(pid) ->
        if Process.alive?(pid) do
          case StreamingJob.get_result(pid) do
            {:ok, wav_data} ->
              conn
              |> put_resp_content_type("audio/wav")
              |> put_resp_header("content-disposition", ~s(attachment; filename="speech.wav"))
              |> send_resp(200, wav_data)

            {:error, :not_completed} ->
              conn
              |> put_status(202)
              |> json(%{status: "processing", message: "Job not yet completed"})

            {:error, reason} ->
              conn
              |> put_status(500)
              |> json(%{error: inspect(reason)})
          end
        else
          conn
          |> put_status(410)
          |> json(%{error: "Job process no longer available"})
        end

      [] ->
        conn
        |> put_status(404)
        |> json(%{error: "Job not found"})
    end
  end
end
