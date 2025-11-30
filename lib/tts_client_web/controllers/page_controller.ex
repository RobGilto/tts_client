defmodule TtsClientWeb.PageController do
  use TtsClientWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
