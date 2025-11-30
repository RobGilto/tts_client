defmodule TtsClient.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :key, :string, null: false
      add :value, :text

      timestamps()
    end

    create unique_index(:settings, [:key])
  end
end
