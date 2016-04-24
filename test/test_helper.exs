defmodule TestHelper do
  @fixtures_path "./test/fixtures/"

  def read_fixture(file_name) do
    {:ok, html} = File.read(@fixtures_path <> file_name)
    html
  end
end

ExUnit.start()
