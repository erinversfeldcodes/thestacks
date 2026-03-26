defmodule Mix.Tasks.ProtoSync.DriftChecker do
  @moduledoc "Compares generated file content against disk for drift detection."

  @doc """
  Compares generated content against an existing file on disk.

  Returns `:ok` if the files match (after whitespace normalization),
  `{:drift, path, diff}` if they differ, or `{:drift, path, "file not found"}`
  if the file doesn't exist.
  """
  def check(expected_content, file_path) do
    if File.exists?(file_path) do
      actual = File.read!(file_path)

      if normalize(actual) == normalize(expected_content) do
        :ok
      else
        diff = generate_diff(actual, expected_content)
        {:drift, file_path, diff}
      end
    else
      {:drift, file_path, "file not found — expected generated file at #{file_path}"}
    end
  end

  defp normalize(content) do
    content
    |> String.trim()
    |> String.replace(~r/\s+$\n/m, "\n")
  end

  defp generate_diff(actual, expected) do
    actual_lines = String.split(normalize(actual), "\n")
    expected_lines = String.split(normalize(expected), "\n")

    List.myers_difference(actual_lines, expected_lines)
    |> Enum.flat_map(fn
      {:eq, _} -> []
      {:del, lines} -> Enum.map(lines, &"- #{&1}")
      {:ins, lines} -> Enum.map(lines, &"+ #{&1}")
    end)
    |> Enum.join("\n")
    |> case do
      "" -> "(whitespace-only differences)"
      diff -> diff
    end
  end
end
