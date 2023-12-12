defmodule TestHelper do
  @fixtures_path "./test/fixtures/"

  def read_fixture(file_name) do
    {:ok, html} = File.read(@fixtures_path <> file_name)
    html
  end

  def read_parse_fixture(file_name) do
    file_name
    |> read_fixture()
    |> Floki.parse_document!()
  end
end

ExUnit.start()
