defmodule PhoenixKitDashboards.Test.Layouts do
  @moduledoc """
  Minimal layouts for the LiveView test endpoint.

  `app/1` renders flashes (info / error / warning) with stable IDs so tests can
  assert on flash content without depending on the host app's real layout.
  """
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Test</title>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <div id="test-flashes">
      <div :if={msg = Phoenix.Flash.get(@flash, :info)} id="flash-info" data-flash-kind="info">
        {msg}
      </div>
      <div :if={msg = Phoenix.Flash.get(@flash, :error)} id="flash-error" data-flash-kind="error">
        {msg}
      </div>
      <div
        :if={msg = Phoenix.Flash.get(@flash, :warning)}
        id="flash-warning"
        data-flash-kind="warning"
      >
        {msg}
      </div>
    </div>
    {@inner_content}
    """
  end

  # Phoenix's error pipeline will try to render "<status>.html"; give it a
  # minimal catch-all so a raising LV surfaces the reason instead of a
  # "no function clause" template error.
  def render(_template, assigns) do
    ~H"""
    <html>
      <body>
        <h1>Error</h1>
        <pre>{inspect(assigns[:reason] || assigns[:conn])}</pre>
      </body>
    </html>
    """
  end
end
