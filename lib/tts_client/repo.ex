defmodule TtsClient.Repo do
  use Ecto.Repo,
    otp_app: :tts_client,
    adapter: Ecto.Adapters.Postgres
end
